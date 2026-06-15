import { sha256Base64URL } from "./hash.js";
import { normalizeEmail } from "./email.js";
import { normalizeLicenseCode } from "./licenseCode.js";

export interface ActivateProofMessageInput {
  email: string;
  licenseCode: string;
  installIdHash: string;
  devicePublicKey: string;
  bundleId: string;
  appVersion?: string | null;
  osVersion?: string | null;
  clientNonce: string;
  createdAt: string;
}

export function buildActivateProofMessage(input: ActivateProofMessageInput): string {
  const appVersion = input.appVersion?.trim() || "-";
  const osVersion = input.osVersion?.trim() || "-";
  return [
    "PromptStudio-Activate-Proof-v1",
    `emailSha256:${sha256Base64URL(normalizeEmail(input.email))}`,
    `licenseCodeSha256:${sha256Base64URL(normalizeLicenseCode(input.licenseCode))}`,
    `installIdHash:${input.installIdHash}`,
    `devicePublicKey:${input.devicePublicKey}`,
    `bundleId:${input.bundleId}`,
    `appVersion:${appVersion}`,
    `osVersion:${osVersion}`,
    `clientNonce:${input.clientNonce}`,
    `createdAt:${input.createdAt}`
  ].join("\n");
}

export function buildDeviceProofMessage(input: {
  activationId: string;
  challengeId: string;
  nonce: string;
  bundleId: string;
}): string {
  return [
    "PromptStudio-Device-Proof-v1",
    `activationId:${input.activationId}`,
    `challengeId:${input.challengeId}`,
    `nonce:${input.nonce}`,
    `bundleId:${input.bundleId}`
  ].join("\n");
}
