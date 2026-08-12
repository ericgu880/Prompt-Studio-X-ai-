const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  DEV_EXTENSION_ID,
  DEV_MANIFEST_KEY,
  extensionIdFromManifestKey,
  isProductionExtensionId,
} = require('../extension-config.js');

const extensionRoot = path.join(__dirname, '..');

test('manifest is MV3, injects into all URLs, and permits native messaging only', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(extensionRoot, 'manifest.json'), 'utf8'));
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.host_permissions, ['<all_urls>']);
  assert.ok(manifest.permissions.includes('nativeMessaging'));
  assert.ok(manifest.content_scripts.some((entry) => entry.matches.includes('<all_urls>')));
  assert.equal(manifest.background.service_worker, 'background.js');
  assert.ok(!manifest.background.type || manifest.background.type === 'module');
  assert.ok(!manifest.permissions.includes('tabs'));
  assert.equal(manifest.key, DEV_MANIFEST_KEY);
  assert.equal(extensionIdFromManifestKey(manifest.key), DEV_EXTENSION_ID);
});

test('development manifest key is public material and release IDs are explicit production IDs', () => {
  assert.match(DEV_MANIFEST_KEY, /^[A-Za-z0-9+/]+={0,2}$/);
  assert.equal(DEV_MANIFEST_KEY.includes('PRIVATE'), false);
  assert.equal(isProductionExtensionId(''), false);
  assert.equal(isProductionExtensionId(DEV_EXTENSION_ID), false);
  assert.equal(isProductionExtensionId('abcdefghijklmnopabcdefghijklmnop'), true);
  assert.equal(isProductionExtensionId('abcdefghijklmnopabcdefghijklmnop!'), false);
});

test('extension scripts contain no network client calls', () => {
  for (const file of ['selection.js', 'content-core.js', 'content.js', 'background-logic.js', 'background.js', 'extension-config.js']) {
    const source = fs.readFileSync(path.join(extensionRoot, file), 'utf8');
    assert.doesNotMatch(source, /\bfetch\s*\(|XMLHttpRequest|WebSocket/);
  }
});

test('content script does not read selection text during selectionchange', () => {
  const source = fs.readFileSync(path.join(extensionRoot, 'content.js'), 'utf8');
  assert.doesNotMatch(source, /selection\.(toString|textContent)\s*\(/);
  assert.match(source, /readSelectionAtClick\(/);
});
