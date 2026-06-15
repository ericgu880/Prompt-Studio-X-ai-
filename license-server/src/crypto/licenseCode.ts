import { randomBytes } from "node:crypto";
import { hmacSha256Hex } from "./hash.js";

const CROCKFORD = "23456789ABCDEFGHJKMNPQRSTVWXYZ";

export function normalizeLicenseCode(input: string): string {
  return input.trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
}

export function generateLicenseCode(): string {
  let body = "";
  while (body.length < 20) {
    for (const byte of randomBytes(20)) {
      body += CROCKFORD[byte % CROCKFORD.length];
      if (body.length === 20) break;
    }
  }
  return `PS-${body.slice(0, 4)}-${body.slice(4, 8)}-${body.slice(8, 12)}-${body.slice(12, 16)}-${body.slice(16, 20)}`;
}

export function hashLicenseCode(pepper: string, input: string): string {
  return hmacSha256Hex(pepper, normalizeLicenseCode(input));
}

export function codePrefix(displayCode: string): string {
  const normalized = normalizeLicenseCode(displayCode);
  return `${normalized.slice(0, 2)}-${normalized.slice(2, 6)}`;
}

export function maskLicenseCode(displayCode: string): string {
  const normalized = normalizeLicenseCode(displayCode);
  const prefix = `${normalized.slice(0, 2)}-${normalized.slice(2, 6)}`;
  const suffix = normalized.slice(-4);
  return `${prefix}-****-****-${suffix}`;
}
