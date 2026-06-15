import { hmacSha256Hex } from "./hash.js";

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

export function hashEmail(pepper: string, email: string): string {
  return hmacSha256Hex(pepper, normalizeEmail(email));
}

export function maskEmail(email: string): string {
  const normalized = normalizeEmail(email);
  const [local, domain] = normalized.split("@");
  if (!local || !domain) return "***";
  const visible = local.slice(0, 1);
  return `${visible}***@${domain}`;
}
