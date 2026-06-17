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
}

export function loadConfig(): AppConfig {
  return {
    nodeEnv: process.env.NODE_ENV ?? "development",
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
    adminSessionSecret: optionalSecret("ADMIN_SESSION_SECRET")
  };
}
