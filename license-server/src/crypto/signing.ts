import {
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign,
  verify,
  type KeyObject
} from "node:crypto";
import { base64urlDecode, base64urlEncode } from "./base64url.js";

const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export function privateKeyFromPKCS8DerBase64(value: string): KeyObject {
  return createPrivateKey({
    key: Buffer.from(value, "base64"),
    format: "der",
    type: "pkcs8"
  });
}

export function rawPublicKeyToSPKIDer(rawPublicKey: Buffer): Buffer {
  if (rawPublicKey.length !== 32) {
    throw new Error("Ed25519 raw public key must be 32 bytes");
  }
  return Buffer.concat([ED25519_SPKI_PREFIX, rawPublicKey]);
}

export function publicKeyFromRawBase64URL(rawBase64URL: string): KeyObject {
  return createPublicKey({
    key: rawPublicKeyToSPKIDer(base64urlDecode(rawBase64URL)),
    format: "der",
    type: "spki"
  });
}

export function rawPublicKeyFromSPKIDer(spkiDer: Buffer): Buffer {
  if (spkiDer.length < 32 || !spkiDer.subarray(0, spkiDer.length - 32).equals(ED25519_SPKI_PREFIX)) {
    throw new Error("Invalid Ed25519 SPKI DER public key");
  }
  return spkiDer.subarray(spkiDer.length - 32);
}

export function signEd25519(message: string | Buffer, privateKey: KeyObject): string {
  return base64urlEncode(sign(null, Buffer.isBuffer(message) ? message : Buffer.from(message, "utf8"), privateKey));
}

export function verifyEd25519(message: string | Buffer, signatureBase64URL: string, publicKey: KeyObject): boolean {
  return verify(
    null,
    Buffer.isBuffer(message) ? message : Buffer.from(message, "utf8"),
    publicKey,
    base64urlDecode(signatureBase64URL)
  );
}

export function generateEd25519KeyFixture(): {
  privateKeyPKCS8DerB64: string;
  publicKeySPKIDerB64: string;
  publicKeyRawB64URL: string;
} {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const privateDer = privateKey.export({ format: "der", type: "pkcs8" }) as Buffer;
  const publicDer = publicKey.export({ format: "der", type: "spki" }) as Buffer;
  return {
    privateKeyPKCS8DerB64: privateDer.toString("base64"),
    publicKeySPKIDerB64: publicDer.toString("base64"),
    publicKeyRawB64URL: base64urlEncode(rawPublicKeyFromSPKIDer(publicDer))
  };
}
