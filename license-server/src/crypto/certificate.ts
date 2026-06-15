import type { KeyObject } from "node:crypto";
import { base64urlDecode, base64urlEncode } from "./base64url.js";
import { sha256Hex } from "./hash.js";
import { signEd25519, verifyEd25519, publicKeyFromRawBase64URL } from "./signing.js";

export interface LicenseCertificatePayload {
  iss: string;
  aud: string;
  bundleId: string;
  licenseId: string;
  activationId: string;
  customerEmailHash: string;
  plan: string;
  licenseType: string;
  status: string;
  seatLimit: number;
  features: string[];
  majorVersion: number;
  updatesUntil: string | null;
  deviceKeyThumbprint: string;
  issuedAt: string;
  refreshAfter: string;
  expiresAt: string;
  graceUntil: string;
  serverTime: string;
}

export interface LicenseCertificateHeader {
  typ: "PS-LICENSE-CERT";
  alg: "EdDSA";
  kid: string;
  v: 1;
}

export function signCertificate(
  payload: LicenseCertificatePayload,
  kid: string,
  privateKey: KeyObject
): string {
  const header: LicenseCertificateHeader = { typ: "PS-LICENSE-CERT", alg: "EdDSA", kid, v: 1 };
  const headerPart = base64urlEncode(JSON.stringify(header));
  const payloadPart = base64urlEncode(JSON.stringify(payload));
  const signingInput = `${headerPart}.${payloadPart}`;
  const signature = signEd25519(signingInput, privateKey);
  return `${signingInput}.${signature}`;
}

export function certificateHash(certificate: string): string {
  return sha256Hex(certificate);
}

export function verifyCertificateWithRawPublicKey(certificate: string, rawPublicKeyB64URL: string): LicenseCertificatePayload {
  const parts = certificate.split(".");
  if (parts.length !== 3) throw new Error("Invalid certificate format");
  const [headerPart, payloadPart, signaturePart] = parts;
  const header = JSON.parse(base64urlDecode(headerPart).toString("utf8")) as LicenseCertificateHeader;
  if (header.alg !== "EdDSA" || header.typ !== "PS-LICENSE-CERT") {
    throw new Error("Invalid certificate header");
  }
  const publicKey = publicKeyFromRawBase64URL(rawPublicKeyB64URL);
  if (!verifyEd25519(`${headerPart}.${payloadPart}`, signaturePart, publicKey)) {
    throw new Error("Invalid certificate signature");
  }
  return JSON.parse(base64urlDecode(payloadPart).toString("utf8")) as LicenseCertificatePayload;
}
