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

async function loginCookie(app: Awaited<ReturnType<typeof buildApp>>): Promise<string> {
  const response = await app.inject({
    method: "POST",
    url: "/admin/login",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    payload: "token=secret-token"
  });
  return String(response.headers["set-cookie"]);
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

  it("validates create license form input before writing", async () => {
    const app = await buildApp(prismaStub(), config({ adminToken: "secret-token", adminSessionSecret: "session-secret" }));
    const cookie = await loginCookie(app);
    const response = await app.inject({
      method: "POST",
      url: "/admin/licenses",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        cookie
      },
      payload: "email=not-an-email&plan=pro_lifetime&seats=0"
    });
    await app.close();

    expect(response.statusCode).toBe(400);
    expect(response.body).toContain("无法生成激活码");
    expect(response.body).toContain("购买邮箱格式不正确");
    expect(response.body).toContain("设备数至少为 1");
  });
});
