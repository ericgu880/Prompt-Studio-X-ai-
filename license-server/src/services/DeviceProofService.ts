import { isBase64URL, base64urlDecode } from "../crypto/base64url.js";
import { hmacSha256Hex, sha256Base64URL } from "../crypto/hash.js";
import { publicKeyFromRawBase64URL, verifyEd25519 } from "../crypto/signing.js";
import { buildActivateProofMessage, buildDeviceProofMessage } from "../crypto/proof.js";
import type { AppConfig } from "../config.js";

export class DeviceProofService {
  constructor(private readonly config: AppConfig) {}

  validateRawPublicKey(rawPublicKeyBase64URL: string): Buffer {
    if (!isBase64URL(rawPublicKeyBase64URL)) {
      throw new Error("INVALID_DEVICE_PUBLIC_KEY");
    }
    const raw = base64urlDecode(rawPublicKeyBase64URL);
    if (raw.length !== 32) {
      throw new Error("INVALID_DEVICE_PUBLIC_KEY");
    }
    return raw;
  }

  deviceKeyThumbprint(rawPublicKeyBase64URL: string): string {
    return sha256Base64URL(this.validateRawPublicKey(rawPublicKeyBase64URL));
  }

  nonceHash(clientNonce: string, deviceKeyThumbprint: string): string {
    return hmacSha256Hex(this.config.licenseCodePepper, `${clientNonce}:${deviceKeyThumbprint}`);
  }

  verifyActivateProof(input: {
    email: string;
    licenseCode: string;
    installIdHash: string;
    devicePublicKey: string;
    bundleId: string;
    appVersion?: string | null;
    osVersion?: string | null;
    clientNonce: string;
    createdAt: string;
    signature: string;
  }): void {
    if (input.bundleId !== this.config.bundleId) {
      throw new Error("INVALID_BUNDLE_ID");
    }
    if (!isBase64URL(input.clientNonce) || base64urlDecode(input.clientNonce).length < 16) {
      throw new Error("INVALID_ACTIVATE_PROOF");
    }
    const createdAt = Date.parse(input.createdAt);
    if (!Number.isFinite(createdAt) || Math.abs(Date.now() - createdAt) > 10 * 60 * 1000) {
      throw new Error("INVALID_ACTIVATE_PROOF");
    }
    const message = buildActivateProofMessage(input);
    const publicKey = publicKeyFromRawBase64URL(input.devicePublicKey);
    if (!verifyEd25519(message, input.signature, publicKey)) {
      throw new Error("INVALID_ACTIVATE_PROOF");
    }
  }

  verifyDeviceProof(input: {
    activationId: string;
    challengeId: string;
    nonce: string;
    bundleId: string;
    signature: string;
    devicePublicKey: string;
  }): void {
    const message = buildDeviceProofMessage(input);
    const publicKey = publicKeyFromRawBase64URL(input.devicePublicKey);
    if (!verifyEd25519(message, input.signature, publicKey)) {
      throw new Error("INVALID_DEVICE_PROOF");
    }
  }
}
