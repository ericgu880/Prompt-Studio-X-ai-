import { createHmac, createHash } from "node:crypto";
import { base64urlEncode } from "./base64url.js";

export function sha256Base64URL(input: string | Buffer): string {
  return base64urlEncode(createHash("sha256").update(input).digest());
}

export function sha256Hex(input: string | Buffer): string {
  return createHash("sha256").update(input).digest("hex");
}

export function hmacSha256Hex(secret: string, input: string): string {
  return createHmac("sha256", secret).update(input).digest("hex");
}

export function hmacSha256Base64URL(secret: string, input: string): string {
  return base64urlEncode(createHmac("sha256", secret).update(input).digest());
}
