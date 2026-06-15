import { describe, expect, it } from "vitest";
import { privateKeyFromPKCS8DerBase64, generateEd25519KeyFixture } from "../src/crypto/signing.js";
import { signCertificate, verifyCertificateWithRawPublicKey } from "../src/crypto/certificate.js";

describe("license certificates", () => {
  it("signs with PKCS8 DER and verifies with raw public key", () => {
    const fixture = generateEd25519KeyFixture();
    const privateKey = privateKeyFromPKCS8DerBase64(fixture.privateKeyPKCS8DerB64);
    const certificate = signCertificate(
      {
        iss: "promptstudio-license-server",
        aud: "promptstudio-macos",
        bundleId: "com.promptstudio.app",
        licenseId: "lic_test",
        activationId: "act_test",
        customerEmailHash: "email_hash",
        plan: "pro_lifetime",
        licenseType: "lifetime",
        status: "active",
        seatLimit: 2,
        features: ["pro.create_prompt"],
        majorVersion: 1,
        updatesUntil: null,
        deviceKeyThumbprint: "thumb",
        issuedAt: "2026-06-15T00:00:00.000Z",
        refreshAfter: "2026-06-22T00:00:00.000Z",
        expiresAt: "2026-07-15T00:00:00.000Z",
        graceUntil: "2026-07-29T00:00:00.000Z",
        serverTime: "2026-06-15T00:00:00.000Z"
      },
      "dev-key-1",
      privateKey
    );

    expect(verifyCertificateWithRawPublicKey(certificate, fixture.publicKeyRawB64URL).activationId).toBe("act_test");
    const parts = certificate.split(".");
    const tampered = `${parts[0]}.${parts[1].replace(/.$/, parts[1].endsWith("A") ? "B" : "A")}.${parts[2]}`;
    expect(() => verifyCertificateWithRawPublicKey(tampered, fixture.publicKeyRawB64URL)).toThrow();
  });
});
