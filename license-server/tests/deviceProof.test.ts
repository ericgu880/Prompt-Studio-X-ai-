import { describe, expect, it } from "vitest";
import type { AppConfig } from "../src/config.js";
import { buildActivateProofMessage } from "../src/crypto/proof.js";
import { generateEd25519KeyFixture, privateKeyFromPKCS8DerBase64, signEd25519 } from "../src/crypto/signing.js";
import { base64urlEncode } from "../src/crypto/base64url.js";
import { DeviceProofService } from "../src/services/DeviceProofService.js";

function testConfig(): AppConfig {
  return {
    nodeEnv: "test",
    port: 8787,
    databaseUrl: "postgresql://unused",
    licenseCodePepper: "test-pepper",
    signingPrivateKeyPKCS8DerB64: "unused",
    signingPublicKeyRawB64URL: "unused",
    signingKeyId: "dev-key-1",
    certificateIssuer: "promptstudio-license-server",
    certificateAudience: "promptstudio-macos",
    bundleId: "com.promptstudio.app",
    certificateDays: 30,
    graceDays: 14,
    refreshAfterDays: 7,
    rateLimitEnabled: false
  };
}

describe("device proofs", () => {
  it("verifies activate proof signatures from the device key", () => {
    const fixture = generateEd25519KeyFixture();
    const service = new DeviceProofService(testConfig());
    const createdAt = new Date().toISOString();
    const input = {
      email: "user@example.com",
      licenseCode: "PS-7K4D-M9QF-2X8P-R6TA-B3HE",
      installIdHash: "install_hash",
      devicePublicKey: fixture.publicKeyRawB64URL,
      bundleId: "com.promptstudio.app",
      appVersion: "1.0.0",
      osVersion: "macOS 15.5",
      clientNonce: base64urlEncode(Buffer.alloc(32, 7)),
      createdAt
    };
    const signature = signEd25519(buildActivateProofMessage(input), privateKeyFromPKCS8DerBase64(fixture.privateKeyPKCS8DerB64));

    expect(() => service.verifyActivateProof({ ...input, signature })).not.toThrow();
    expect(service.deviceKeyThumbprint(fixture.publicKeyRawB64URL)).toHaveLength(43);
  });

  it("rejects invalid activate proof signatures without consuming a nonce", () => {
    const fixture = generateEd25519KeyFixture();
    const other = generateEd25519KeyFixture();
    const service = new DeviceProofService(testConfig());
    const input = {
      email: "user@example.com",
      licenseCode: "PS-7K4D-M9QF-2X8P-R6TA-B3HE",
      installIdHash: "install_hash",
      devicePublicKey: fixture.publicKeyRawB64URL,
      bundleId: "com.promptstudio.app",
      appVersion: "1.0.0",
      osVersion: "macOS 15.5",
      clientNonce: base64urlEncode(Buffer.alloc(32, 8)),
      createdAt: new Date().toISOString()
    };
    const signature = signEd25519(buildActivateProofMessage(input), privateKeyFromPKCS8DerBase64(other.privateKeyPKCS8DerB64));

    expect(() => service.verifyActivateProof({ ...input, signature })).toThrow("INVALID_ACTIVATE_PROOF");
  });

  it("rejects activate proofs for another bundle id", () => {
    const fixture = generateEd25519KeyFixture();
    const service = new DeviceProofService(testConfig());
    const input = {
      email: "user@example.com",
      licenseCode: "PS-7K4D-M9QF-2X8P-R6TA-B3HE",
      installIdHash: "install_hash",
      devicePublicKey: fixture.publicKeyRawB64URL,
      bundleId: "com.other.app",
      appVersion: "1.0.0",
      osVersion: "macOS 15.5",
      clientNonce: base64urlEncode(Buffer.alloc(32, 9)),
      createdAt: new Date().toISOString()
    };
    const signature = signEd25519(buildActivateProofMessage(input), privateKeyFromPKCS8DerBase64(fixture.privateKeyPKCS8DerB64));

    expect(() => service.verifyActivateProof({ ...input, signature })).toThrow("INVALID_BUNDLE_ID");
  });
});
