import {
  createHash,
  createHmac,
  generateKeyPairSync,
  randomBytes,
  randomUUID,
  sign,
  type KeyObject,
} from "node:crypto";
import { readFileSync } from "node:fs";
import { PrismaClient } from "@prisma/client";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AppConfig } from "../src/config.js";
import { SecretBox } from "../src/crypto/secretBox.js";
import {
  buildActivateProofMessage,
  buildDeviceProofMessage,
  buildRecoveryProofMessage,
} from "../src/crypto/proof.js";
import { EmailOutboxWorker } from "../src/services/EmailOutboxWorker.js";

const testDatabaseURL = process.env.TEST_DATABASE_URL;
const integrationDescribe = testDatabaseURL ? describe : describe.skip;

interface TestDevice {
  label: string;
  installIdHash: string;
  publicKey: string;
  privateKey: KeyObject;
}

function fixture(name: string): string {
  return readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8").trim();
}

function makeConfig(databaseUrl: string): AppConfig {
  return {
    nodeEnv: "test",
    port: 8787,
    databaseUrl,
    licenseCodePepper: "commercial-flow-test-pepper",
    signingPrivateKeyPKCS8DerB64: fixture("ed25519_dev_private.pkcs8.der.b64"),
    signingPublicKeyRawB64URL: fixture("ed25519_dev_public.raw.b64url"),
    signingPublicKeySPKIDerB64: fixture("ed25519_dev_public.spki.der.b64"),
    signingKeyId: "dev-key-1",
    certificateIssuer: "promptstudio-license-server",
    certificateAudience: "promptstudio-macos",
    bundleId: "com.creatigo.promptstudio",
    certificateDays: 30,
    graceDays: 14,
    refreshAfterDays: 7,
    rateLimitEnabled: false,
    adminToken: "test-admin-token",
    adminSessionSecret: "test-admin-session-secret-with-at-least-32-characters",
    adminCsrfSecret: "test-admin-csrf-secret",
    adminHmacSecret: "test-admin-hmac-secret",
    adminWebOrigin: "http://localhost:8000",
    legacyAdminEnabled: false,
    telemetryEnabled: false,
    trustProxyHops: 0,
    commercial: {
      commerceEnabled: true,
      emailEnabled: true,
      dataEncryptionKeyB64: randomBytes(32).toString("base64"),
      publicBaseURL: "http://localhost:8787",
      supportURL: "https://promptstudio.app/support",
      lemonSqueezyWebhookSecret: "commercial-flow-lemon-secret",
      resendApiKey: undefined,
      resendWebhookSecret: undefined,
      resendFromEmail: "PromptStudio <license@promptstudio.app>",
      productMappings: [{
        provider: "lemonsqueezy",
        variantId: "987",
        plan: "pro_lifetime",
        seats: 2,
        majorVersion: 1,
        updatesDays: 365,
      }],
      workerEnabled: false,
      workerPollIntervalMs: 1_000,
      workerLeaseMs: 30_000,
      workerMaxAttempts: 3,
      recoveryTokenMinutes: 15,
      recoveryCooldownSeconds: 60,
    },
  };
}

function makeDevice(label: string): TestDevice {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const spki = publicKey.export({ format: "der", type: "spki" });
  return {
    label,
    installIdHash: createHash("sha256").update(label).digest("base64url"),
    publicKey: spki.subarray(spki.length - 32).toString("base64url"),
    privateKey,
  };
}

function signMessage(message: string, privateKey: KeyObject): string {
  return sign(null, Buffer.from(message), privateKey).toString("base64url");
}

function activationPayload(
  device: TestDevice,
  email: string,
  licenseCode: string,
  replaceActivationId?: string,
) {
  const createdAt = new Date().toISOString();
  const clientNonce = randomBytes(24).toString("base64url");
  const common = {
    email,
    licenseCode,
    installIdHash: device.installIdHash,
    devicePublicKey: device.publicKey,
    deviceLabel: device.label,
    bundleId: "com.creatigo.promptstudio",
    appVersion: "1.0.0",
    osVersion: "macOS 15.5",
    clientNonce,
    createdAt,
  };
  return {
    ...common,
    replaceActivationId,
    deviceProof: {
      version: "PromptStudio-Activate-Proof-v1",
      clientNonce,
      createdAt,
      signature: signMessage(buildActivateProofMessage(common), device.privateKey),
    },
  };
}

function recoveryPayload(
  device: TestDevice,
  recoveryToken: string,
  replaceActivationId?: string,
) {
  const createdAt = new Date().toISOString();
  const clientNonce = randomBytes(24).toString("base64url");
  const common = {
    recoveryToken,
    installIdHash: device.installIdHash,
    devicePublicKey: device.publicKey,
    deviceLabel: device.label,
    bundleId: "com.creatigo.promptstudio",
    appVersion: "1.0.0",
    osVersion: "macOS 15.5",
    clientNonce,
    createdAt,
  };
  return {
    ...common,
    replaceActivationId,
    deviceProof: {
      version: "PromptStudio-Recovery-Proof-v1",
      clientNonce,
      createdAt,
      signature: signMessage(buildRecoveryProofMessage(common), device.privateKey),
    },
  };
}

function deviceProof(
  device: TestDevice,
  activationId: string,
  challengeId: string,
  nonce: string,
) {
  return signMessage(
    buildDeviceProofMessage({
      activationId,
      challengeId,
      nonce,
      bundleId: "com.creatigo.promptstudio",
    }),
    device.privateKey,
  );
}

integrationDescribe("commercial license journey", () => {
  let prisma: PrismaClient;
  let config: AppConfig;

  beforeAll(async () => {
    const url = new URL(testDatabaseURL!);
    const databaseName = url.pathname.toLowerCase();
    const schemaName = (url.searchParams.get("schema") ?? "public").toLowerCase();
    if (!databaseName.includes("test") && !schemaName.includes("test")) {
      throw new Error("TEST_DATABASE_URL must use a database or schema whose name contains 'test'.");
    }
    config = makeConfig(testDatabaseURL!);
    prisma = new PrismaClient({ datasources: { db: { url: testDatabaseURL! } } });
    await prisma.$connect();
    await prisma.$executeRawUnsafe(`
      TRUNCATE TABLE
        "AdminAuditLog", "AdminSession", "AdminIdempotencyRecord", "AdminUser",
        "EmailOutbox", "LicenseRecoveryToken", "CommerceWebhookEvent", "CommerceOrderState",
        "LicenseEvent", "LicenseCertificate", "RefreshChallenge", "Activation",
        "ActivateProofNonce", "License", "Customer"
      RESTART IDENTITY CASCADE
    `);
  });

  it("reconciles a full refund that is processed before its purchase", async () => {
    process.env.LOG_LEVEL = "silent";
    const app = await buildApp(prisma, config);
    const orderId = `refund-first-${randomUUID()}`;
    const email = `refund-first+${randomUUID()}@example.com`;
    const refundBody = JSON.stringify({
      meta: { event_name: "order_refunded" },
      data: {
        id: orderId,
        attributes: {
          total: 9900,
          refunded_amount: 9900,
          refunded_at: new Date().toISOString(),
        },
      },
    });
    const refundSignature = createHmac("sha256", config.commercial.lemonSqueezyWebhookSecret!)
      .update(refundBody)
      .digest("hex");
    expect((await app.inject({
      method: "POST",
      url: "/v1/webhooks/lemonsqueezy",
      headers: { "content-type": "application/json", "x-signature": refundSignature },
      payload: refundBody,
    })).statusCode).toBe(200);
    expect(await app.licenseServices.commerceInbox.runOnce()).toBe(true);
    expect(await prisma.commerceOrderState.findUniqueOrThrow({
      where: { provider_orderId: { provider: "lemonsqueezy", orderId } },
    })).toMatchObject({ fullRefund: true, appliedAt: null });

    const orderBody = JSON.stringify({
      meta: { event_name: "order_created" },
      data: {
        id: orderId,
        attributes: {
          user_email: email,
          created_at: new Date().toISOString(),
          total: 9900,
          refunded_amount: 0,
          first_order_item: { variant_id: 987 },
        },
      },
    });
    const orderSignature = createHmac("sha256", config.commercial.lemonSqueezyWebhookSecret!)
      .update(orderBody)
      .digest("hex");
    expect((await app.inject({
      method: "POST",
      url: "/v1/webhooks/lemonsqueezy",
      headers: { "content-type": "application/json", "x-signature": orderSignature },
      payload: orderBody,
    })).statusCode).toBe(200);
    expect(await app.licenseServices.commerceInbox.runOnce()).toBe(true);

    const license = await prisma.license.findUniqueOrThrow({
      where: { orderProvider_orderId: { orderProvider: "lemonsqueezy", orderId } },
    });
    expect(license).toMatchObject({ status: "refunded", refundedAt: expect.any(Date) });
    expect(await prisma.emailOutbox.count({ where: { licenseId: license.id } })).toBe(0);
    await app.close();
  });

  afterAll(async () => {
    await prisma?.$disconnect();
  });

  it("fulfills, activates, replaces, recovers, refreshes, and revokes one order", async () => {
    process.env.LOG_LEVEL = "silent";
    const app = await buildApp(prisma, config);
    const orderId = `e2e-${randomUUID()}`;
    const email = `e2e+${randomUUID()}@example.com`;
    const orderBody = JSON.stringify({
      meta: { event_name: "order_created" },
      data: {
        id: orderId,
        attributes: {
          user_email: email,
          created_at: new Date().toISOString(),
          total: 9900,
          refunded_amount: 0,
          first_order_item: { variant_id: 987 },
        },
      },
    });
    const signature = createHmac("sha256", config.commercial.lemonSqueezyWebhookSecret!)
      .update(orderBody)
      .digest("hex");

    const firstDelivery = await app.inject({
      method: "POST",
      url: "/v1/webhooks/lemonsqueezy",
      headers: { "content-type": "application/json", "x-signature": signature },
      payload: orderBody,
    });
    const duplicateDelivery = await app.inject({
      method: "POST",
      url: "/v1/webhooks/lemonsqueezy",
      headers: { "content-type": "application/json", "x-signature": signature },
      payload: orderBody,
    });
    expect(firstDelivery.json()).toMatchObject({ ok: true, duplicate: false });
    expect(duplicateDelivery.json()).toMatchObject({ ok: true, duplicate: true });

    expect(await app.licenseServices.commerceInbox.runOnce()).toBe(true);
    const license = await prisma.license.findUniqueOrThrow({
      where: { orderProvider_orderId: { orderProvider: "lemonsqueezy", orderId } },
    });
    expect(license.seatLimit).toBe(2);
    expect(license.updatesUntil?.getTime()).toBeGreaterThan(Date.now() + 360 * 24 * 60 * 60 * 1_000);

    const purchaseOutbox = await prisma.emailOutbox.findFirstOrThrow({
      where: { licenseId: license.id, kind: "purchase" },
    });
    const purchasePayload = JSON.parse(
      new SecretBox(config.commercial.dataEncryptionKeyB64).open(purchaseOutbox.payloadEncrypted!),
    ) as { licenseCode: string };
    const send = vi.fn().mockResolvedValue({ id: "resend-purchase" });
    const emailWorker = new EmailOutboxWorker(prisma, config, { send });
    expect(await emailWorker.runOnce()).toBe(true);
    expect(await prisma.emailOutbox.findUniqueOrThrow({ where: { id: purchaseOutbox.id } }))
      .toMatchObject({ status: "accepted", payloadEncrypted: null });

    const first = makeDevice("First Mac");
    const second = makeDevice("Second Mac");
    const third = makeDevice("Third Mac");
    const firstActivation = await app.inject({
      method: "POST",
      url: "/v1/licenses/activate",
      payload: activationPayload(first, email, purchasePayload.licenseCode),
    });
    const secondActivation = await app.inject({
      method: "POST",
      url: "/v1/licenses/activate",
      payload: activationPayload(second, email, purchasePayload.licenseCode),
    });
    expect(firstActivation.statusCode).toBe(200);
    expect(secondActivation.statusCode).toBe(200);

    const conflict = await app.inject({
      method: "POST",
      url: "/v1/licenses/activate",
      payload: activationPayload(third, email, purchasePayload.licenseCode),
    });
    expect(conflict.statusCode).toBe(409);
    expect(conflict.json()).toMatchObject({
      error: { code: "SEAT_LIMIT_EXCEEDED", data: { deviceCount: 2, seatLimit: 2 } },
    });
    const firstActivationId = firstActivation.json().activationId as string;
    const replacement = await app.inject({
      method: "POST",
      url: "/v1/licenses/activate",
      payload: activationPayload(third, email, purchasePayload.licenseCode, firstActivationId),
    });
    expect(replacement.statusCode).toBe(200);
    expect(await prisma.activation.findUniqueOrThrow({ where: { id: firstActivationId } }))
      .toMatchObject({ status: "deactivated", deactivatedReason: "seat_replaced" });

    const thirdActivationId = replacement.json().activationId as string;
    const challenge = await app.inject({
      method: "POST",
      url: "/v1/licenses/refresh/challenge",
      payload: { activationId: thirdActivationId },
    });
    const challengeBody = challenge.json();
    const refresh = await app.inject({
      method: "POST",
      url: "/v1/licenses/refresh",
      payload: {
        activationId: thirdActivationId,
        challengeId: challengeBody.challengeId,
        signature: deviceProof(third, thirdActivationId, challengeBody.challengeId, challengeBody.nonce),
        appVersion: "1.0.1",
        osVersion: "macOS 15.5",
      },
    });
    expect(refresh.statusCode).toBe(200);
    expect(refresh.json().licenseCertificate).toMatch(/^[^.]+\.[^.]+\.[^.]+$/);

    expect((await app.inject({
      method: "POST",
      url: "/v1/licenses/recover",
      payload: { email },
    })).statusCode).toBe(200);
    const recoveryOutbox = await prisma.emailOutbox.findFirstOrThrow({
      where: { licenseId: license.id, kind: "recovery" },
      orderBy: { createdAt: "desc" },
    });
    const recoveryEmail = JSON.parse(
      new SecretBox(config.commercial.dataEncryptionKeyB64).open(recoveryOutbox.payloadEncrypted!),
    ) as { recoveryToken: string };
    send.mockResolvedValueOnce({ id: "resend-recovery" });
    expect(await emailWorker.runOnce()).toBe(true);

    const fourth = makeDevice("Recovered Mac");
    const recoveryConflict = await app.inject({
      method: "POST",
      url: "/v1/licenses/recovery/activate",
      payload: recoveryPayload(fourth, recoveryEmail.recoveryToken),
    });
    expect(recoveryConflict.statusCode).toBe(409);
    const secondActivationId = secondActivation.json().activationId as string;
    const recoveryActivation = await app.inject({
      method: "POST",
      url: "/v1/licenses/recovery/activate",
      payload: recoveryPayload(fourth, recoveryEmail.recoveryToken, secondActivationId),
    });
    expect(recoveryActivation.statusCode).toBe(200);
    expect(await prisma.licenseRecoveryToken.findUniqueOrThrow({
      where: { id: recoveryOutbox.recoveryTokenId! },
    })).toMatchObject({ consumedAt: expect.any(Date) });

    const refundBody = JSON.stringify({
      meta: { event_name: "order_refunded" },
      data: {
        id: orderId,
        attributes: {
          user_email: email,
          created_at: new Date().toISOString(),
          total: 9900,
          refunded_amount: 9900,
          first_order_item: { variant_id: 987 },
        },
      },
    });
    const refundSignature = createHmac("sha256", config.commercial.lemonSqueezyWebhookSecret!)
      .update(refundBody)
      .digest("hex");
    expect((await app.inject({
      method: "POST",
      url: "/v1/webhooks/lemonsqueezy",
      headers: { "content-type": "application/json", "x-signature": refundSignature },
      payload: refundBody,
    })).statusCode).toBe(200);
    expect(await app.licenseServices.commerceInbox.runOnce()).toBe(true);
    expect(await prisma.license.findUniqueOrThrow({ where: { id: license.id } }))
      .toMatchObject({ status: "refunded", refundedAt: expect.any(Date) });

    const fourthActivationId = recoveryActivation.json().activationId as string;
    const revokedChallenge = await app.inject({
      method: "POST",
      url: "/v1/licenses/refresh/challenge",
      payload: { activationId: fourthActivationId },
    });
    const revokedChallengeBody = revokedChallenge.json();
    const revokedRefresh = await app.inject({
      method: "POST",
      url: "/v1/licenses/refresh",
      payload: {
        activationId: fourthActivationId,
        challengeId: revokedChallengeBody.challengeId,
        signature: deviceProof(
          fourth,
          fourthActivationId,
          revokedChallengeBody.challengeId,
          revokedChallengeBody.nonce,
        ),
      },
    });
    expect(revokedRefresh.statusCode).toBe(403);
    expect(revokedRefresh.json()).toMatchObject({ error: { code: "LICENSE_REVOKED" } });

    await app.close();
  }, 30_000);
});
