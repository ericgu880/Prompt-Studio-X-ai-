import "dotenv/config";
import { createPublicKey, timingSafeEqual } from "node:crypto";
import { base64urlDecode } from "./crypto/base64url.js";
import { privateKeyFromPKCS8DerBase64, rawPublicKeyFromSPKIDer } from "./crypto/signing.js";

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
  if (production && value.length === 0) {
    throw new Error("COMMERCE_PRODUCT_MAPPINGS_JSON must contain at least one product mapping in production");
  }

  const mappings = value.map((entry, index) => {
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
  const variants = new Set<string>();
  for (const mapping of mappings) {
    const key = `${mapping.provider}:${mapping.variantId}`;
    if (variants.has(key)) throw new Error(`Duplicate commerce product mapping: ${key}`);
    variants.add(key);
  }
  return mappings;
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
  trustProxyHops: number;
  commercial: CommercialConfig;
}

export interface OperationalSettings {
  production: boolean;
  certificateDays: number;
  graceDays: number;
  refreshAfterDays: number;
  workerPollIntervalMs: number;
  workerLeaseMs: number;
  workerMaxAttempts: number;
  workerEnabled: boolean;
  recoveryTokenMinutes: number;
  recoveryCooldownSeconds: number;
  trustProxyHops: number;
  adminSessionSecret?: string;
  adminCsrfSecret?: string;
  adminHmacSecret?: string;
  adminWebOrigin: string;
  legacyAdminEnabled: boolean;
}

export function validateOperationalSettings(settings: OperationalSettings): void {
  if (!Number.isInteger(settings.certificateDays) || settings.certificateDays <= 0) {
    throw new Error("LICENSE_CERT_DAYS must be a positive integer");
  }
  if (!Number.isInteger(settings.graceDays) || settings.graceDays < 0) {
    throw new Error("LICENSE_GRACE_DAYS must be a non-negative integer");
  }
  if (!Number.isInteger(settings.refreshAfterDays) || settings.refreshAfterDays <= 0 ||
      settings.refreshAfterDays >= settings.certificateDays) {
    throw new Error("LICENSE_REFRESH_AFTER_DAYS must be positive and less than LICENSE_CERT_DAYS");
  }
  const positiveWorkerValues: Array<[string, number]> = [
    ["WORKER_POLL_INTERVAL_MS", settings.workerPollIntervalMs],
    ["WORKER_LEASE_MS", settings.workerLeaseMs],
    ["WORKER_MAX_ATTEMPTS", settings.workerMaxAttempts],
    ["RECOVERY_TOKEN_MINUTES", settings.recoveryTokenMinutes],
    ["RECOVERY_COOLDOWN_SECONDS", settings.recoveryCooldownSeconds],
  ];
  for (const [name, value] of positiveWorkerValues) {
    if (!Number.isInteger(value) || value <= 0) throw new Error(`${name} must be a positive integer`);
  }
  if (!Number.isInteger(settings.trustProxyHops) || settings.trustProxyHops < 0) {
    throw new Error("TRUST_PROXY_HOPS must be a non-negative integer");
  }
  if (!settings.production) return;
  if (settings.trustProxyHops < 1) {
    throw new Error("TRUST_PROXY_HOPS must explicitly describe the production reverse proxy");
  }
  if (!settings.workerEnabled) {
    throw new Error("WORKER_ENABLED must be true in the production all-in-one service");
  }
  const adminSecrets: Array<[string, string | undefined]> = [
    ["ADMIN_SESSION_SECRET", settings.adminSessionSecret],
    ["ADMIN_CSRF_SECRET", settings.adminCsrfSecret],
    ["ADMIN_HMAC_SECRET", settings.adminHmacSecret],
  ];
  for (const [name, value] of adminSecrets) {
    if (!value || value.length < 32) throw new Error(`${name} must be explicitly set to at least 32 characters in production`);
  }
  if (new Set(adminSecrets.map(([, value]) => value)).size !== adminSecrets.length) {
    throw new Error("Production admin secrets must be distinct");
  }
  const adminOrigin = validatedURL("ADMIN_WEB_ORIGIN", settings.adminWebOrigin, true);
  if (!adminOrigin.startsWith("https://")) throw new Error("ADMIN_WEB_ORIGIN must use HTTPS in production");
  if (settings.legacyAdminEnabled) throw new Error("LEGACY_ADMIN_ENABLED must be false in production");
}

export function validateSigningKeyPair(input: {
  privateKeyPKCS8DerB64: string;
  publicKeyRawB64URL: string;
  publicKeySPKIDerB64?: string;
}): void {
  const privateKey = privateKeyFromPKCS8DerBase64(input.privateKeyPKCS8DerB64);
  if (privateKey.asymmetricKeyType !== "ed25519") {
    throw new Error("LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64 must contain an Ed25519 private key");
  }
  const derivedSPKI = createPublicKey(privateKey).export({ format: "der", type: "spki" }) as Buffer;
  const derivedRaw = rawPublicKeyFromSPKIDer(derivedSPKI);
  const configuredRaw = base64urlDecode(input.publicKeyRawB64URL);
  if (configuredRaw.length !== derivedRaw.length || !timingSafeEqual(configuredRaw, derivedRaw)) {
    throw new Error("LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL does not match the signing private key");
  }
  if (input.publicKeySPKIDerB64) {
    const configuredSPKI = Buffer.from(input.publicKeySPKIDerB64, "base64");
    if (configuredSPKI.length !== derivedSPKI.length || !timingSafeEqual(configuredSPKI, derivedSPKI)) {
      throw new Error("LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64 does not match the signing private key");
    }
  }
}

export function loadConfig(): AppConfig {
  const nodeEnv = process.env.NODE_ENV ?? "development";
  const production = nodeEnv === "production";
  const commerceEnabled = (process.env.COMMERCE_ENABLED ?? "true") === "true";
  const dataEncryptionKeyB64 = required("DATA_ENCRYPTION_KEY_B64");
  if (Buffer.from(dataEncryptionKeyB64, "base64").length !== 32) {
    throw new Error("DATA_ENCRYPTION_KEY_B64 must decode to 32 bytes");
  }
  const lemonSqueezyWebhookSecret = optionalSecret("LEMON_SQUEEZY_WEBHOOK_SECRET");
  const resendApiKey = optionalSecret("RESEND_API_KEY");
  const resendWebhookSecret = optionalSecret("RESEND_WEBHOOK_SECRET");
  if (production && commerceEnabled && !lemonSqueezyWebhookSecret) throw new Error("Missing required environment variable: LEMON_SQUEEZY_WEBHOOK_SECRET");
  if (production && !resendApiKey) throw new Error("Missing required environment variable: RESEND_API_KEY");
  if (production && !resendWebhookSecret) throw new Error("Missing required environment variable: RESEND_WEBHOOK_SECRET");
  const signingPrivateKeyPKCS8DerB64 = required("LICENSE_SIGNING_PRIVATE_KEY_PKCS8_DER_B64");
  const signingPublicKeyRawB64URL = required("LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL");
  const signingPublicKeySPKIDerB64 = optionalSecret("LICENSE_SIGNING_PUBLIC_KEY_SPKI_DER_B64");
  validateSigningKeyPair({
    privateKeyPKCS8DerB64: signingPrivateKeyPKCS8DerB64,
    publicKeyRawB64URL: signingPublicKeyRawB64URL,
    publicKeySPKIDerB64: signingPublicKeySPKIDerB64,
  });
  const certificateDays = numberValue("LICENSE_CERT_DAYS", 30);
  const graceDays = numberValue("LICENSE_GRACE_DAYS", 14);
  const refreshAfterDays = numberValue("LICENSE_REFRESH_AFTER_DAYS", 7);
  const workerPollIntervalMs = numberValue("WORKER_POLL_INTERVAL_MS", 1_000);
  const workerLeaseMs = numberValue("WORKER_LEASE_MS", 30_000);
  const workerMaxAttempts = numberValue("WORKER_MAX_ATTEMPTS", 8);
  const workerEnabled = (process.env.WORKER_ENABLED ?? "true") === "true";
  const recoveryTokenMinutes = numberValue("RECOVERY_TOKEN_MINUTES", 15);
  const recoveryCooldownSeconds = numberValue("RECOVERY_COOLDOWN_SECONDS", 60);
  const trustProxyHops = numberValue("TRUST_PROXY_HOPS", 0);
  const adminSessionSecret = optionalSecret("ADMIN_SESSION_SECRET");
  const configuredAdminCsrfSecret = optionalSecret("ADMIN_CSRF_SECRET");
  const configuredAdminHmacSecret = optionalSecret("ADMIN_HMAC_SECRET");
  const adminCsrfSecret = configuredAdminCsrfSecret ?? adminSessionSecret ?? "promptstudio-admin-dev-csrf";
  const adminHmacSecret = configuredAdminHmacSecret ?? adminSessionSecret ?? "promptstudio-admin-dev-hmac";
  const adminWebOrigin = process.env.ADMIN_WEB_ORIGIN ?? "http://localhost:8000";
  const legacyAdminEnabled = (process.env.LEGACY_ADMIN_ENABLED ?? (production ? "false" : "true")) === "true";
  validateOperationalSettings({
    production,
    certificateDays,
    graceDays,
    refreshAfterDays,
    workerPollIntervalMs,
    workerLeaseMs,
    workerMaxAttempts,
    workerEnabled,
    recoveryTokenMinutes,
    recoveryCooldownSeconds,
    trustProxyHops,
    adminSessionSecret,
    adminCsrfSecret: configuredAdminCsrfSecret,
    adminHmacSecret: configuredAdminHmacSecret,
    adminWebOrigin,
    legacyAdminEnabled,
  });

  return {
    nodeEnv,
    port: numberValue("PORT", 8787),
    databaseUrl: required("DATABASE_URL"),
    licenseCodePepper: required("LICENSE_CODE_PEPPER"),
    signingPrivateKeyPKCS8DerB64,
    signingPublicKeyRawB64URL,
    signingPublicKeySPKIDerB64,
    signingKeyId: required("LICENSE_SIGNING_KEY_ID"),
    certificateIssuer: process.env.LICENSE_CERTIFICATE_ISSUER ?? "promptstudio-license-server",
    certificateAudience: process.env.LICENSE_CERTIFICATE_AUDIENCE ?? "promptstudio-macos",
    bundleId: process.env.LICENSE_BUNDLE_ID ?? "com.creatigo.promptstudio",
    certificateDays,
    graceDays,
    refreshAfterDays,
    rateLimitEnabled: (process.env.RATE_LIMIT_ENABLED ?? "true") === "true",
    adminToken: optionalSecret("ADMIN_TOKEN"),
    adminSessionSecret,
    adminCsrfSecret,
    adminHmacSecret,
    adminWebOrigin,
    legacyAdminEnabled,
    telemetryEnabled: (process.env.TELEMETRY_ENABLED ?? "false") === "true",
    trustProxyHops,
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
      productMappings: parseProductMappings(process.env.COMMERCE_PRODUCT_MAPPINGS_JSON, production && commerceEnabled),
      workerEnabled,
      workerPollIntervalMs,
      workerLeaseMs,
      workerMaxAttempts,
      recoveryTokenMinutes,
      recoveryCooldownSeconds,
    }
  };
}
