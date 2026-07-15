import "dotenv/config";

function required(name: string): string {
  const value = process.env[name];
  if (!value || value.startsWith("replace-with-")) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function numberValue(name: string, fallback: number): number {
  const value = process.env[name];
  if (!value) return fallback;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) throw new Error(`Invalid number environment variable: ${name}`);
  return parsed;
}

function optionalSecret(name: string): string | undefined {
  const value = process.env[name];
  if (!value || value.startsWith("replace-with-")) return undefined;
  return value;
}

export interface ProductMapping {
  provider: "lemonsqueezy";
  variantId: string;
  plan: "pro_lifetime";
  seats: number;
  majorVersion: number;
  updatesDays: number;
}

export interface CommercialConfig {
  dataEncryptionKeyB64: string;
  publicBaseURL: string;
  supportURL: string;
  lemonSqueezyWebhookSecret?: string;
  resendApiKey?: string;
  resendWebhookSecret?: string;
  resendFromEmail: string;
  productMappings: ProductMapping[];
  workerEnabled: boolean;
  workerPollIntervalMs: number;
  workerLeaseMs: number;
  workerMaxAttempts: number;
  recoveryTokenMinutes: number;
  recoveryCooldownSeconds: number;
}

function parseProductMappings(raw: string | undefined, production: boolean): ProductMapping[] {
  if (!raw) {
    if (production) throw new Error("Missing required environment variable: COMMERCE_PRODUCT_MAPPINGS_JSON");
    return [];
  }

  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error("COMMERCE_PRODUCT_MAPPINGS_JSON must be valid JSON");
  }
  if (!Array.isArray(value)) throw new Error("COMMERCE_PRODUCT_MAPPINGS_JSON must be an array");

  return value.map((entry, index) => {
    const item = entry as Partial<ProductMapping>;
    if (
      item.provider !== "lemonsqueezy" ||
      typeof item.variantId !== "string" ||
      item.variantId.length === 0 ||
      item.plan !== "pro_lifetime" ||
      !Number.isInteger(item.seats) ||
      Number(item.seats) < 1 ||
      !Number.isInteger(item.majorVersion) ||
      Number(item.majorVersion) < 1 ||
      !Number.isInteger(item.updatesDays) ||
      Number(item.updatesDays) < 1
    ) {
      throw new Error(`Invalid commerce product mapping at index ${index}`);
    }
    return item as ProductMapping;
  });
}

function validatedURL(name: string, value: string, requireHTTPS: boolean): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${name} must be a valid URL`);
  }
  if (requireHTTPS && url.protocol !== "https:") throw new Error(`${name} must use HTTPS in production`);
  return url.toString().replace(/\/$/, "");
}

export interface AppConfig {
  nodeEnv: string;
  port: number;
  databaseUrl: string;
  licenseCodePepper: string;
  signingPrivateKeyPKCS8DerB64: string;
  signingPublicKeyRawB64URL: string;
  signingPublicKeySPKIDerB64?: string;
  signingKeyId: string;
  certificateIssuer: string;
  certificateAudience: string;
  bundleId: string;
  certificateDays: number;
  graceDays: number;
  refreshAfterDays: number;
  rateLimitEnabled: boolean;
  adminToken?: string;
  adminSessionSecret?: string;
  adminCsrfSecret: string;
  adminHmacSecret: string;
  adminWebOrigin: string;
  legacyAdminEnabled: boolean;
  telemetryEnabled: boolean;
  commercial: CommercialConfig;
}

export function loadConfig(): AppConfig {
  const nodeEnv = process.env.NODE_ENV ?? "development";
  const production = nodeEnv === "production";
  const dataEncryptionKeyB64 = required("DATA_ENCRYPTION_KEY_B64");
  if (Buffer.from(dataEncryptionKeyB64, "base64").length !== 32) {
    throw new Error("DATA_ENCRYPTION_KEY_B64 must decode to 32 bytes");
  }
  const lemonSqueezyWebhookSecret = optionalSecret("LEMON_SQUEEZY_WEBHOOK_SECRET");
  const resendApiKey = optionalSecret("RESEND_API_KEY");
  const resendWebhookSecret = optionalSecret("RESEND_WEBHOOK_SECRET");
  if (production && !lemonSqueezyWebhookSecret) throw new Error("Missing required environment variable: LEMON_SQUEEZY_WEBHOOK_SECRET");
  if (production && !resendApiKey) throw new Error("Missing required environment variable: RESEND_API_KEY");
  if (production && !resendWebhookSecret) throw new Error("Missing required environment variable: RESEND_WEBHOOK_SECRET");

  return {
    nodeEnv,
    port: numberValue("PORT", 8787),
    databaseUrl: required("DATABASE_URL"),
    licenseCodePepper: required("LICENSE_CODE_PEPPER"),
    signingPrivateKeyPKCS8DerB64: required("LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64"),
    signingPublicKeyRawB64URL: required("LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL"),
    signingPublicKeySPKIDerB64: process.env.LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64,
    signingKeyId: required("LICENSE_SIGNING_KEY_ID"),
    certificateIssuer: process.env.LICENSE_CERTIFICATE_ISSUER ?? "promptstudio-license-server",
    certificateAudience: process.env.LICENSE_CERTIFICATE_AUDIENCE ?? "promptstudio-macos",
    bundleId: process.env.LICENSE_BUNDLE_ID ?? "com.creatigo.promptstudio",
    certificateDays: numberValue("LICENSE_CERT_DAYS", 30),
    graceDays: numberValue("LICENSE_GRACE_DAYS", 14),
    refreshAfterDays: numberValue("LICENSE_REFRESH_AFTER_DAYS", 7),
    rateLimitEnabled: (process.env.RATE_LIMIT_ENABLED ?? "true") === "true",
    adminToken: optionalSecret("ADMIN_TOKEN"),
    adminSessionSecret: optionalSecret("ADMIN_SESSION_SECRET"),
    adminCsrfSecret: process.env.ADMIN_CSRF_SECRET ?? process.env.ADMIN_SESSION_SECRET ?? "promptstudio-admin-dev-csrf",
    adminHmacSecret: process.env.ADMIN_HMAC_SECRET ?? process.env.ADMIN_SESSION_SECRET ?? "promptstudio-admin-dev-hmac",
    adminWebOrigin: process.env.ADMIN_WEB_ORIGIN ?? "http://localhost:8000",
    legacyAdminEnabled: (process.env.LEGACY_ADMIN_ENABLED ?? (process.env.NODE_ENV === "production" ? "false" : "true")) === "true",
    telemetryEnabled: (process.env.TELEMETRY_ENABLED ?? "false") === "true",
    commercial: {
      dataEncryptionKeyB64,
      publicBaseURL: validatedURL(
        "PUBLIC_BASE_URL",
        process.env.PUBLIC_BASE_URL ?? "http://localhost:8787",
        production,
      ),
      supportURL: validatedURL(
        "SUPPORT_URL",
        process.env.SUPPORT_URL ?? "https://promptstudio.app/support",
        production,
      ),
      lemonSqueezyWebhookSecret,
      resendApiKey,
      resendWebhookSecret,
      resendFromEmail: process.env.RESEND_FROM_EMAIL ?? "PromptStudio <license@promptstudio.app>",
      productMappings: parseProductMappings(process.env.COMMERCE_PRODUCT_MAPPINGS_JSON, production),
      workerEnabled: (process.env.WORKER_ENABLED ?? "true") === "true",
      workerPollIntervalMs: numberValue("WORKER_POLL_INTERVAL_MS", 1_000),
      workerLeaseMs: numberValue("WORKER_LEASE_MS", 30_000),
      workerMaxAttempts: numberValue("WORKER_MAX_ATTEMPTS", 8),
      recoveryTokenMinutes: numberValue("RECOVERY_TOKEN_MINUTES", 15),
      recoveryCooldownSeconds: numberValue("RECOVERY_COOLDOWN_SECONDS", 60),
    }
  };
}
