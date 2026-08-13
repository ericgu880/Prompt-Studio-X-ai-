import { afterEach, describe, expect, it, vi } from "vitest";
import { loadConfig, validateOperationalSettings } from "../src/config.js";
import { generateEd25519KeyFixture } from "../src/crypto/signing.js";

function validSettings() {
  return {
    production: true,
    certificateDays: 30,
    graceDays: 14,
    refreshAfterDays: 7,
    workerPollIntervalMs: 1_000,
    workerLeaseMs: 30_000,
    workerMaxAttempts: 8,
    workerEnabled: true,
    recoveryTokenMinutes: 15,
    recoveryCooldownSeconds: 60,
    trustProxyHops: 1,
    adminSessionSecret: "s".repeat(32),
    adminCsrfSecret: "c".repeat(32),
    adminHmacSecret: "h".repeat(32),
    adminWebOrigin: "https://admin.promptstudio.app",
    legacyAdminEnabled: false,
  };
}

describe("production configuration", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("accepts coherent certificate, worker, proxy, and admin settings", () => {
    expect(() => validateOperationalSettings(validSettings())).not.toThrow();
  });

  it("rejects incoherent certificate and worker durations", () => {
    expect(() => validateOperationalSettings({
      ...validSettings(),
      refreshAfterDays: 30,
    })).toThrow(/refresh/i);
    expect(() => validateOperationalSettings({
      ...validSettings(),
      workerMaxAttempts: 0,
    })).toThrow(/worker/i);
  });

  it("fails closed when production admin or proxy settings are unsafe", () => {
    expect(() => validateOperationalSettings({
      ...validSettings(),
      adminSessionSecret: undefined,
    })).toThrow(/ADMIN_SESSION_SECRET/);
    expect(() => validateOperationalSettings({
      ...validSettings(),
      adminWebOrigin: "http://admin.promptstudio.app",
    })).toThrow(/HTTPS/);
    expect(() => validateOperationalSettings({
      ...validSettings(),
      trustProxyHops: 0,
    })).toThrow(/TRUST_PROXY_HOPS/);
    expect(() => validateOperationalSettings({
      ...validSettings(),
      workerEnabled: false,
    })).toThrow(/WORKER_ENABLED/);
  });

  it("rejects an empty production commerce product mapping", () => {
    const signing = generateEd25519KeyFixture();
    const environment: Record<string, string> = {
      NODE_ENV: "production",
      DATABASE_URL: "postgresql://promptstudio:secret@db/promptstudio",
      LICENSE_CODE_PEPPER: "test-license-code-pepper",
      LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64: signing.privateKeyPKCS8DerB64,
      LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL: signing.publicKeyRawB64URL,
      LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64: signing.publicKeySPKIDerB64,
      LICENSE_SIGNING_KEY_ID: "production-key-1",
      DATA_ENCRYPTION_KEY_B64: Buffer.alloc(32, 1).toString("base64"),
      LEMON_SQUEEZY_WEBHOOK_SECRET: "test-lemon-secret",
      RESEND_API_KEY: "test-resend-key",
      RESEND_WEBHOOK_SECRET: "test-resend-webhook-secret",
      ADMIN_SESSION_SECRET: "s".repeat(32),
      ADMIN_CSRF_SECRET: "c".repeat(32),
      ADMIN_HMAC_SECRET: "h".repeat(32),
      ADMIN_WEB_ORIGIN: "https://admin.promptstudio.app",
      LEGACY_ADMIN_ENABLED: "false",
      WORKER_ENABLED: "true",
      TRUST_PROXY_HOPS: "1",
      PUBLIC_BASE_URL: "https://license.promptstudio.app",
      SUPPORT_URL: "https://promptstudio.app/support",
      COMMERCE_PRODUCT_MAPPINGS_JSON: "[]",
    };
    for (const [name, value] of Object.entries(environment)) vi.stubEnv(name, value);

    expect(() => loadConfig()).toThrow(/COMMERCE_PRODUCT_MAPPINGS_JSON.*at least one/i);
  });

  it("allows a production manual-sales deployment without Lemon Squeezy configuration", () => {
    const signing = generateEd25519KeyFixture();
    const environment: Record<string, string> = {
      NODE_ENV: "production",
      DATABASE_URL: "postgresql://promptstudio:secret@db/promptstudio",
      LICENSE_CODE_PEPPER: "test-license-code-pepper",
      LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64: signing.privateKeyPKCS8DerB64,
      LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL: signing.publicKeyRawB64URL,
      LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64: signing.publicKeySPKIDerB64,
      LICENSE_SIGNING_KEY_ID: "production-key-1",
      DATA_ENCRYPTION_KEY_B64: Buffer.alloc(32, 1).toString("base64"),
      COMMERCE_ENABLED: "false",
      LEMON_SQUEEZY_WEBHOOK_SECRET: "",
      COMMERCE_PRODUCT_MAPPINGS_JSON: "",
      EMAIL_ENABLED: "false",
      RESEND_API_KEY: "",
      RESEND_WEBHOOK_SECRET: "",
      ADMIN_SESSION_SECRET: "s".repeat(32),
      ADMIN_CSRF_SECRET: "c".repeat(32),
      ADMIN_HMAC_SECRET: "h".repeat(32),
      ADMIN_WEB_ORIGIN: "https://admin.promptstudio.app",
      LEGACY_ADMIN_ENABLED: "false",
      WORKER_ENABLED: "true",
      TRUST_PROXY_HOPS: "1",
      PUBLIC_BASE_URL: "https://license.promptstudio.app",
      SUPPORT_URL: "https://promptstudio.app/support",
    };
    for (const [name, value] of Object.entries(environment)) vi.stubEnv(name, value);

    const config = loadConfig();
    expect(config.commercial.commerceEnabled).toBe(false);
    expect(config.commercial.emailEnabled).toBe(false);
  });
});
