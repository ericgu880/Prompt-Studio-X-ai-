import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { SecretBox } from "../src/crypto/secretBox.js";

describe("SecretBox", () => {
  it("round-trips plaintext without exposing it", () => {
    const box = new SecretBox(randomBytes(32).toString("base64"));
    const envelope = box.seal("buyer@example.com");

    expect(envelope).not.toContain("buyer@example.com");
    expect(box.open(envelope)).toBe("buyer@example.com");
  });

  it("uses a fresh nonce for every encrypted value", () => {
    const box = new SecretBox(randomBytes(32).toString("base64"));

    expect(box.seal("same value")).not.toBe(box.seal("same value"));
  });

  it("rejects the wrong key and modified authentication data", () => {
    const box = new SecretBox(randomBytes(32).toString("base64"));
    const otherBox = new SecretBox(randomBytes(32).toString("base64"));
    const envelope = box.seal("sensitive");
    const bytes = Buffer.from(envelope, "base64url");
    bytes[bytes.length - 1] ^= 1;

    expect(() => otherBox.open(envelope)).toThrow("Unable to decrypt protected data");
    expect(() => box.open(bytes.toString("base64url"))).toThrow("Unable to decrypt protected data");
  });

  it("requires exactly 32 bytes of key material", () => {
    expect(() => new SecretBox(Buffer.alloc(16).toString("base64"))).toThrow(
      "DATA_ENCRYPTION_KEY_B64 must decode to 32 bytes",
    );
  });
});
