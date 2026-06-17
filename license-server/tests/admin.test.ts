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

describe("admin web auth", () => {
  it("shows disabled page when ADMIN_TOKEN is not set", async () => {
    const app = await buildApp(prismaStub(), config());
    const response = await app.inject({ method: "GET", url: "/admin/login" });
    await app.close();

    expect(response.statusCode).toBe(200);
    expect(response.body).toContain("后台未启用");
  });

  it("redirects unauthenticated admin requests to login", async () => {
    const app = await buildApp(prismaStub(), config({ adminToken: "secret-token", adminSessionSecret: "session-secret" }));
    const response = await app.inject({ method: "GET", url: "/admin" });
    await app.close();

    expect(response.statusCode).toBe(303);
    expect(response.headers.location).toBe("/admin/login");
  });

  it("rejects an invalid admin token", async () => {
    const app = await buildApp(prismaStub(), config({ adminToken: "secret-token", adminSessionSecret: "session-secret" }));
    const response = await app.inject({
      method: "POST",
      url: "/admin/login",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      payload: "token=wrong"
    });
    await app.close();

    expect(response.statusCode).toBe(401);
    expect(response.body).toContain("Token 不正确");
  });

  it("sets a signed admin session cookie after login", async () => {
    const app = await buildApp(prismaStub(), config({ adminToken: "secret-token", adminSessionSecret: "session-secret" }));
    const response = await app.inject({
      method: "POST",
      url: "/admin/login",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      payload: "token=secret-token"
    });
    await app.close();

    expect(response.statusCode).toBe(303);
    expect(response.headers.location).toBe("/admin");
    expect(response.headers["set-cookie"]).toContain("ps_admin=");
    expect(response.headers["set-cookie"]).toContain("HttpOnly");
  });
});
