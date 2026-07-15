import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

const VERSION = 1;
const IV_BYTES = 12;
const TAG_BYTES = 16;

export class SecretBox {
  private readonly key: Buffer;

  constructor(keyBase64: string) {
    const key = Buffer.from(keyBase64, "base64");
    if (key.length !== 32) {
      throw new Error("DATA_ENCRYPTION_KEY_B64 must decode to 32 bytes");
    }
    this.key = key;
  }

  seal(plaintext: string): string {
    const iv = randomBytes(IV_BYTES);
    const cipher = createCipheriv("aes-256-gcm", this.key, iv);
    const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
    const tag = cipher.getAuthTag();

    return Buffer.concat([Buffer.from([VERSION]), iv, tag, ciphertext]).toString("base64url");
  }

  open(envelope: string): string {
    try {
      const data = Buffer.from(envelope, "base64url");
      if (data.length < 1 + IV_BYTES + TAG_BYTES || data[0] !== VERSION) {
        throw new Error("invalid envelope");
      }
      const ivStart = 1;
      const tagStart = ivStart + IV_BYTES;
      const ciphertextStart = tagStart + TAG_BYTES;
      const decipher = createDecipheriv("aes-256-gcm", this.key, data.subarray(ivStart, tagStart));
      decipher.setAuthTag(data.subarray(tagStart, ciphertextStart));
      return Buffer.concat([
        decipher.update(data.subarray(ciphertextStart)),
        decipher.final(),
      ]).toString("utf8");
    } catch {
      throw new Error("Unable to decrypt protected data");
    }
  }
}
