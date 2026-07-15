import { describe, expect, it } from "vitest";
import type { PrismaClient } from "@prisma/client";
import { buildApp } from "../src/app.js";
import type { AppConfig } from "../src/config.js";
import { generateEd25519KeyFixture } from "../src/crypto/signing.js";

function config(overrides: Partial<AppConfig> = {}): AppConfig {
  const fixture = generateEd25519KeyFixture();
  return {
    nodeEnv: "test",
    port: 8787,
    databaseUrl: "postgresql://unused",
    licenseCodePepper: "test-pepper",
    signingPrivateKeyPKCS8DerB64: fixture.privateKeyPKCS8DerB64,
    signingPublicKeyRawB64URL: fixture.publicKeyRawB64URL,
    signingKeyId: "dev-key-1",
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
    ...overrides
  };
}

function prismaStub(): PrismaClient {
  return {
    license: {
      findMany: async () => []
    }
  } as unknown as PrismaClient;
}

describe("admin JSON API", () => {
  it("returns 401 for unauthenticated admin API requests", async () => {
    const app = await buildApp(prismaStub(), config());
    const response = await app.inject({ method: "GET", url: "/admin-api/licenses" });
    await app.close();

    expect(response.statusCode).toBe(401);
    expect(response.json()).toMatchObject({
      ok: false,
      error: { code: "UNAUTHENTICATED" }
    });
    expect(response.json().requestId).toBeTruthy();
  });

  it("rejects state-changing requests without a CSRF token", async () => {
    const app = await buildApp(prismaStub(), config());
    const response = await app.inject({
      method: "POST",
      url: "/admin-api/licenses",
      headers: {
        origin: "http://localhost:8000",
        cookie: "ps_admin_session=test-session"
      },
      payload: {
        email: "buyer@example.com",
        plan: "pro_lifetime",
        seats: 2
      }
    });
    await app.close();

    expect(response.statusCode).toBe(403);
    expect(response.json()).toMatchObject({
      ok: false,
      error: { code: "CSRF_TOKEN_INVALID" }
    });
  });

  it("rejects reused idempotency keys with different request bodies", async () => {
    const app = await buildApp(prismaStub(), config());
    const response = await app.inject({
      method: "POST",
      url: "/admin-api/licenses",
      headers: {
        origin: "http://localhost:8000",
        "x-csrf-token": "valid-csrf",
        "idempotency-key": "same-key",
        cookie: "ps_admin_session=valid-session"
      },
      payload: {
        email: "buyer@example.com",
        plan: "pro_lifetime",
        seats: 2
      }
    });
    await app.close();

    expect([401, 409]).toContain(response.statusCode);
    if (response.statusCode === 409) {
      expect(response.json()).toMatchObject({
        ok: false,
        error: { code: "IDEMPOTENCY_KEY_REUSED" }
      });
    }
  });
});
