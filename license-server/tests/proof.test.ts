import { describe, expect, it } from "vitest";
import { buildActivateProofMessage, buildDeviceProofMessage } from "../src/crypto/proof.js";

describe("proof messages", () => {
  it("builds activate proof messages with fixed order", () => {
    expect(buildActivateProofMessage({
      email: "USER@example.com",
      licenseCode: "ps 7k4d",
      installIdHash: "install",
      devicePublicKey: "pub",
      bundleId: "com.promptstudio.app",
      appVersion: "1.0.0",
      osVersion: "macOS 15.5",
      clientNonce: "nonce",
      createdAt: "2026-06-15T00:00:00.000Z"
    })).toBe([
      "PromptStudio-Activate-Proof-v1",
      "emailSha256:tMmiiTI7IaAcPpQPFQ65uMVCWH8av9jw4cwf_F5HVRQ",
      "licenseCodeSha256:aZmwkQchVEemBtWQSYXK96lhBHEM4Twixkb9gZieKPM",
      "installIdHash:install",
      "devicePublicKey:pub",
      "bundleId:com.promptstudio.app",
      "appVersion:1.0.0",
      "osVersion:macOS 15.5",
      "clientNonce:nonce",
      "createdAt:2026-06-15T00:00:00.000Z"
    ].join("\n"));
  });

  it("builds refresh/deactivate proof messages with fixed order", () => {
    expect(buildDeviceProofMessage({
      activationId: "act",
      challengeId: "ch",
      nonce: "nonce",
      bundleId: "com.promptstudio.app"
    })).toBe([
      "PromptStudio-Device-Proof-v1",
      "activationId:act",
      "challengeId:ch",
      "nonce:nonce",
      "bundleId:com.promptstudio.app"
    ].join("\n"));
  });
});
