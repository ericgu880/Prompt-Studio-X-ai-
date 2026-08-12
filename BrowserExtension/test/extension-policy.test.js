const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

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
});

test('extension scripts contain no network client calls', () => {
  for (const file of ['selection.js', 'content.js', 'background.js']) {
    const source = fs.readFileSync(path.join(extensionRoot, file), 'utf8');
    assert.doesNotMatch(source, /\bfetch\s*\(|XMLHttpRequest|WebSocket/);
  }
});
