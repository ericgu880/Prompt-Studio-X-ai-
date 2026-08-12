import type { PrismaClient } from "@prisma/client";
import { describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import type { AppConfig } from "../src/config.js";
import { generateEd25519KeyFixture } from "../src/crypto/signing.js";
import { createShutdownHandler } from "../src/lifecycle.js";

function appConfig(): AppConfig {
  const signing = generateEd25519KeyFixture();
  return {
    nodeEnv: "test",
    port: 8787,
    databaseUrl: "postgresql://unused",
    licenseCodePepper: "test-pepper",
    signingPrivateKeyPKCS8DerB64: signing.privateKeyPKCS8DerB64,
    signingPublicKeyRawB64URL: signing.publicKeyRawB64URL,
    signingKeyId: "test-key",
    certificateIssuer: "promptstudio-license-server",
    certificateAudience: "promptstudio-macos",
    bundleId: "com.creatigo.promptstudio",
    certificateDays: 30,
    graceDays: 14,
    refreshAfterDays: 7,
    rateLimitEnabled: false,
    adminWebOrigin: "http://localhost:8000",
    adminSessionSecret: "session-secret",
    adminCsrfSecret: "csrf-secret",
    adminHmacSecret: "hmac-secret",
    legacyAdminEnabled: true,
    trustProxyHops: 0,
    commercial: {
      commerceEnabled: true,
      emailEnabled: true,
      dataEncryptionKeyB64: "unused",
      publicBaseURL: "http://localhost:8787",
      supportURL: "https://promptstudio.app/support",
      resendFromEmail: "PromptStudio <license@promptstudio.app>",
      productMappings: [],
      workerEnabled: false,
      workerPollIntervalMs: 1_000,
      workerLeaseMs: 30_000,
      workerMaxAttempts: 4,
      recoveryTokenMinutes: 15,
      recoveryCooldownSeconds: 60,
    },
  };
}

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((fulfill) => { resolve = fulfill; });
  return { promise, resolve };
}

describe("server lifecycle", () => {
  it("does not start the commerce worker when manual sales mode is enabled", async () => {
    const config = appConfig();
    config.commercial.commerceEnabled = false;
    config.commercial.workerEnabled = true;
    const app = await buildApp({} as PrismaClient, config);
    const commerceStart = vi.spyOn(app.licenseServices.commerceInbox, "start");
    const emailStart = vi.spyOn(app.licenseServices.emailWorker, "start").mockImplementation(() => {});

    await app.ready();

    expect(commerceStart).not.toHaveBeenCalled();
    expect(emailStart).toHaveBeenCalledTimes(1);
    await app.close();
  });

  it("does not start the email worker before Resend is configured", async () => {
    const config = appConfig();
    config.commercial.emailEnabled = false;
    config.commercial.workerEnabled = true;
    const app = await buildApp({} as PrismaClient, config);
    const commerceStart = vi.spyOn(app.licenseServices.commerceInbox, "start").mockImplementation(() => {});
    const emailStart = vi.spyOn(app.licenseServices.emailWorker, "start");

    await app.ready();

    expect(commerceStart).toHaveBeenCalledTimes(1);
    expect(emailStart).not.toHaveBeenCalled();
    await app.close();
  });

  it("closes Fastify and Prisma exactly once during repeated termination signals", async () => {
    const shutdownOrder: string[] = [];
    const app = {
      close: vi.fn(async () => { shutdownOrder.push("fastify"); }),
      log: { info: vi.fn(), error: vi.fn() },
    };
    const prisma = { $disconnect: vi.fn(async () => { shutdownOrder.push("database"); }) };
    const exit = vi.fn();
    const shutdown = createShutdownHandler(app, prisma, exit);

    await Promise.all([shutdown("SIGTERM"), shutdown("SIGINT")]);

    expect(app.close).toHaveBeenCalledTimes(1);
    expect(prisma.$disconnect).toHaveBeenCalledTimes(1);
    expect(shutdownOrder).toEqual(["fastify", "database"]);
    expect(exit).toHaveBeenCalledWith(0);
  });

  it("waits for in-flight background workers before Fastify close completes", async () => {
    const app = await buildApp({} as PrismaClient, appConfig());
    await app.ready();
    const commerceDrain = deferred();
    const emailDrain = deferred();
    vi.spyOn(app.licenseServices.commerceInbox, "stopAndDrain").mockReturnValue(commerceDrain.promise);
    vi.spyOn(app.licenseServices.emailWorker, "stopAndDrain").mockReturnValue(emailDrain.promise);

    let closed = false;
    const closing = app.close().then(() => { closed = true; });
    await Promise.resolve();
    expect(closed).toBe(false);

    commerceDrain.resolve();
    await Promise.resolve();
    expect(closed).toBe(false);

    emailDrain.resolve();
    await closing;
    expect(closed).toBe(true);
  });

  it("reports a worker shutdown error without blocking the remaining worker", async () => {
    const app = await buildApp({} as PrismaClient, appConfig());
    await app.ready();
    const timeout = new Error("worker shutdown timed out");
    const errorLog = vi.spyOn(app.log, "error").mockImplementation(() => {});
    vi.spyOn(app.licenseServices.commerceInbox, "stopAndDrain").mockRejectedValue(timeout);
    const emailStop = vi.spyOn(app.licenseServices.emailWorker, "stopAndDrain").mockResolvedValue();

    await expect(app.close()).resolves.toBeUndefined();

    expect(emailStop).toHaveBeenCalledTimes(1);
    expect(errorLog).toHaveBeenCalledWith(
      { err: timeout, worker: "commerce-inbox" },
      "Background worker shutdown did not complete cleanly",
    );
  });
});
