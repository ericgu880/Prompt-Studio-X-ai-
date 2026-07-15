import type { PrismaClient } from "@prisma/client";
import { describe, expect, it, vi } from "vitest";
import type { AppConfig } from "../src/config.js";
import { ActivationService, LicenseAPIError } from "../src/services/ActivationService.js";

function fixture() {
  const now = new Date("2026-07-15T00:00:00.000Z");
  const oldActivation = {
    id: "old-device",
    licenseId: "license-1",
    installIdHash: "old-install",
    devicePublicKey: "old-public-key",
    deviceKeyThumbprint: "old-thumbprint",
    deviceLabel: "Old Mac",
    platform: "macos",
    osVersion: "macOS 15",
    appVersion: "1.0",
    status: "active",
    activatedAt: now,
    lastSeenAt: now,
    deactivatedAt: null,
    deactivatedReason: null,
    replacedByActivationId: null,
  };
  const license = {
    id: "license-1",
    customerId: "customer-1",
    customer: { emailHash: "email-hash" },
    codePrefix: "PS-2345",
    codeHash: "code-hash",
    codeMasked: "PS-2345-****",
    plan: "pro_lifetime",
    licenseType: "lifetime",
    status: "active",
    seatLimit: 1,
    majorVersion: 1,
    updatesUntil: new Date("2027-07-15T00:00:00.000Z"),
    orderProvider: "lemonsqueezy",
    orderId: "order-1",
    createdAt: now,
    activatedAt: now,
    revokedAt: null,
    revokedReason: null,
    refundedAt: null,
    notes: null,
    version: 0,
    activations: [oldActivation],
  };
  const calls: string[] = [];
  const tx = {
    activateProofNonce: { create: vi.fn() },
    licenseRecoveryToken: {
      findUnique: vi.fn().mockResolvedValue({
        id: "recovery-1",
        consumedAt: null,
        expiresAt: new Date("2099-01-01T00:00:00.000Z"),
        requestEmailHash: "email-hash",
        license,
      }),
      updateMany: vi.fn(async () => { calls.push("consume-token"); return { count: 1 }; }),
    },
    activation: {
      update: vi.fn(async ({ where, data }) => { calls.push(`update:${where.id}`); return { ...oldActivation, ...data }; }),
      create: vi.fn(async ({ data }) => {
        calls.push("create-device");
        return { ...data, status: "active", activatedAt: now, deactivatedAt: null, deactivatedReason: null, replacedByActivationId: null };
      }),
      count: vi.fn().mockResolvedValue(1),
    },
    license: { update: vi.fn() },
    licenseEvent: { create: vi.fn() },
  };
  const prisma = {
    activateProofNonce: { findUnique: vi.fn().mockResolvedValue(null) },
    $transaction: async (action: (client: typeof tx) => unknown) => action(tx),
  } as unknown as PrismaClient;
  const certificates = {
    issue: vi.fn(async () => {
      calls.push("issue-certificate");
      return {
        certificate: "signed-certificate",
        refreshAfter: now,
        expiresAt: now,
        graceUntil: now,
        issuedAt: now,
      };
    }),
  };
  const deviceProof = {
    deviceKeyThumbprint: vi.fn().mockReturnValue("new-thumbprint"),
    nonceHash: vi.fn().mockReturnValue("nonce-hash"),
    verifyRecoveryProof: vi.fn(),
  };
  const recovery = { hashToken: vi.fn().mockReturnValue("token-hash") };
  const config = { bundleId: "com.creatigo.promptstudio" } as AppConfig;
  const service = new ActivationService(
    prisma,
    config,
    {} as never,
    certificates as never,
    deviceProof as never,
    recovery as never,
  );
  const input = {
    recoveryToken: "r".repeat(32),
    installIdHash: "new-install",
    devicePublicKey: "new-public-key",
    deviceProof: {
      version: "PromptStudio-Recovery-Proof-v1",
      clientNonce: "nonce",
      createdAt: now.toISOString(),
      signature: "signature",
    },
    deviceLabel: "New Mac",
    bundleId: "com.creatigo.promptstudio",
    appVersion: "1.1",
    osVersion: "macOS 16",
  };
  return { service, input, tx, calls, certificates };
}

describe("recovery activation", () => {
  it("atomically replaces a device before consuming the one-time token", async () => {
    const { service, input, tx, calls } = fixture();
    const result = await service.activateWithRecovery({ ...input, replaceActivationId: "old-device" });

    expect(result.licenseCertificate).toBe("signed-certificate");
    expect(tx.activation.update).toHaveBeenCalledWith(expect.objectContaining({
      where: { id: "old-device" },
      data: expect.objectContaining({ status: "deactivated", deactivatedReason: "seat_replaced" }),
    }));
    expect(calls.indexOf("update:old-device")).toBeLessThan(calls.indexOf("create-device"));
    expect(calls.indexOf("issue-certificate")).toBeLessThan(calls.indexOf("consume-token"));
  });

  it("keeps the recovery token usable when the user still needs to choose a seat", async () => {
    const { service, input, tx, certificates } = fixture();

    await expect(service.activateWithRecovery(input)).rejects.toMatchObject<Partial<LicenseAPIError>>({
      code: "SEAT_LIMIT_EXCEEDED",
      statusCode: 409,
    });
    expect(certificates.issue).not.toHaveBeenCalled();
    expect(tx.licenseRecoveryToken.updateMany).not.toHaveBeenCalled();
  });

  it("rejects replacement ids outside the authorized license", async () => {
    const { service, input } = fixture();

    await expect(
      service.activateWithRecovery({ ...input, replaceActivationId: "foreign-device" }),
    ).rejects.toMatchObject<Partial<LicenseAPIError>>({ code: "DEVICE_NOT_REPLACEABLE" });
  });
});
