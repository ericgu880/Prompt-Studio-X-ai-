const crypto = require('node:crypto');

// This is the DER SubjectPublicKeyInfo for the development extension. It is public material only;
// no private key is stored in the repository. Chrome derives the extension ID from SHA-256(DER).
const DEV_MANIFEST_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmmGicvyxnVTcBGVnSnkzWRmYPIQTVouaFe+yPL1LvPHbZjIMOwZrrkMLr5TZa7qooxHeUZQ4/MJEHjz/KTLXrtZ3fxE3kfvWSvx0KkV2+Lqf8xGLJNjqIJhEcBnVg0rT5ok9gtuL0oU922aExFjjEkXctM1Ounw/3qBPJcu6gasnT5WFgn61WRmZAWTiVflr3l67qrsylC6KR+90yjdtvNSW5EsEtPtlLz3Qwczbr92ICIupqTbbD6LT5m1EzUXhVqcoKhY5OIslYsDF5QCdSh2oIb9CkTb47rAqgiRNd+tdFv7ALvUsEy8M29lA1GHqCP5CKhfE5nNTbboz4mbD8wIDAQAB';
const ID_ALPHABET = 'abcdefghijklmnop';

function extensionIdFromManifestKey(key) {
  const der = Buffer.from(String(key), 'base64');
  if (!der.length) throw new Error('manifest-key-empty');
  const digest = crypto.createHash('sha256').update(der).digest();
  let id = '';
  for (const byte of digest.subarray(0, 16)) id += ID_ALPHABET[byte >> 4] + ID_ALPHABET[byte & 15];
  return id;
}

const DEV_EXTENSION_ID = extensionIdFromManifestKey(DEV_MANIFEST_KEY);

function isExtensionId(value) {
  return typeof value === 'string' && /^[a-p]{32}$/.test(value);
}

function isProductionExtensionId(value) {
  return isExtensionId(value) && value !== DEV_EXTENSION_ID;
}

module.exports = { DEV_MANIFEST_KEY, DEV_EXTENSION_ID, extensionIdFromManifestKey, isExtensionId, isProductionExtensionId };
