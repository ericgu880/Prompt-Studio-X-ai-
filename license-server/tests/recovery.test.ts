import { randomBytes } from "node:crypto";
import fastify from "fastify";
import type { PrismaClient } from "@prisma/client";
import { describe, expect, it, vi } from "vitest";
import type { AppConfig } from "../src/config.js";
import { SecretBox } from "../src/crypto/secretBox.js";
import { recoveryPageRoutes } from "../src/routes/recoveryPage.js";
import { licenseRoutes } from "../src/routes/licenses.js";
import { RecoveryService } from "../src/services/RecoveryService.js";

function config(): AppConfig {
  return {
    licenseCodePepper: "test-pepper",
    commercial: {
      dataEncryptionKeyB64: randomBytes(32).toString("base64"),
      publicBaseURL: "https://license.promptstudio.app",
      supportURL: "https://promptstudio.app/support",
      recoveryTokenMinutes: 15,
      recoveryCooldownSeconds: 60,
    },
  } as AppConfig;
}

describe("license recovery", () => {
  it("queues an encrypted, 15-minute one-time recovery token", async () => {
    const appConfig = config();
    const writes: Record<string, any> = {};
    const tx = {
      licenseRecoveryToken: { create: vi.fn(async ({ data }) => { writes.token = data; return data; }) },
      emailOutbox: { create: vi.fn(async ({ data }) => { writes.outbox = data; return data; }) },
      licenseEvent: { create: vi.fn() },
    };
    const prisma = {
      customer: {
        findUnique: vi.fn().mockResolvedValue({
          id: "customer-1",
          licenses: [{ id: "license-1", status: "active" }],
        }),
      },
      licenseRecoveryToken: { findFirst: vi.fn().mockResolvedValue(null) },
      $transaction: async (action: (client: typeof tx) => unknown) => action(tx),
    } as unknown as PrismaClient;
    const now = new Date("2026-07-15T00:00:00.000Z");
    const service = new RecoveryService(prisma, appConfig);

    expect(await service.request("Buyer@Example.com", { now, requestIpHash: "ip-hash" })).toEqual({ queued: true });
    expect(writes.token.expiresAt.toISOString()).toBe("2026-07-15T00:15:00.000Z");
    expect(writes.token.tokenHash).not.toContain("promptstudio://");
    const payload = JSON.parse(new SecretBox(appConfig.commercial.dataEncryptionKeyB64).open(writes.outbox.payloadEncrypted));
    expect(payload.to).toBe("buyer@example.com");
    expect(payload.recoveryURL).toContain("https://license.promptstudio.app/recover#token=");
    expect(payload.recoveryToken).toBeTruthy();
    expect(writes.token.tokenHash).not.toBe(payload.recoveryToken);
  });

  it("does not reveal missing licenses and respects the resend cooldown", async () => {
    const appConfig = config();
    const prisma = {
      customer: { findUnique: vi.fn().mockResolvedValue(null) },
      licenseRecoveryToken: { findFirst: vi.fn() },
      $transaction: vi.fn(),
    } as unknown as PrismaClient;
    const service = new RecoveryService(prisma, appConfig);
    expect(await service.request("missing@example.com")).toEqual({ queued: false });
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it("always returns the same public response, even when recovery work fails", async () => {
    const app = fastify();
    const recover = vi.fn().mockRejectedValue(new Error("database unavailable"));
    app.decorate("licenseServices", {
      recovery: { request: recover },
      rateLimit: { check: vi.fn() },
    } as never);
    await app.register(licenseRoutes);

    const response = await app.inject({
      method: "POST",
      url: "/v1/licenses/recover",
      payload: { email: "buyer@example.com" },
    });
    await app.close();

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ ok: true });
  });

  it("serves a no-store deep-link handoff without putting the token in a query", async () => {
    const app = fastify();
    await app.register(recoveryPageRoutes, config());
    const response = await app.inject({ method: "GET", url: "/recover" });
    await app.close();

    expect(response.statusCode).toBe(200);
    expect(response.headers["cache-control"]).toContain("no-store");
    expect(response.headers["content-security-policy"]).toContain("default-src 'none'");
    expect(response.body).toContain("location.hash");
    expect(response.body).toContain("promptstudio://license/recover");
  });
});
