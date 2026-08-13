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

test('manifest is MV3, injects into all frames, and adds only image-capture permissions', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(extensionRoot, 'manifest.json'), 'utf8'));
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.host_permissions, ['<all_urls>']);
  assert.ok(manifest.permissions.includes('nativeMessaging'));
  assert.ok(manifest.permissions.includes('contextMenus'));
  assert.ok(manifest.permissions.includes('scripting'));
  assert.deepEqual([...manifest.permissions].sort(), ['contextMenus', 'nativeMessaging', 'scripting'].sort());
  assert.ok(manifest.content_scripts.some((entry) => entry.matches.includes('<all_urls>')));
  assert.ok(manifest.content_scripts.some((entry) => entry.all_frames === true));
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

test('extension scripts contain no network client calls outside the dedicated image acquisition module', () => {
  for (const file of ['selection.js', 'content-core.js', 'content.js', 'background-logic.js', 'extension-config.js']) {
    const source = fs.readFileSync(path.join(extensionRoot, file), 'utf8');
    assert.doesNotMatch(source, /\bfetch\s*\(|XMLHttpRequest|WebSocket/);
  }
  const imageSource = fs.readFileSync(path.join(extensionRoot, 'image-capture.js'), 'utf8');
  assert.match(imageSource, /fetch\s*\(/);
  const backgroundSource = fs.readFileSync(path.join(extensionRoot, 'background.js'), 'utf8');
  assert.match(backgroundSource, /executeMainStoreStart[\s\S]*fetch\s*\(/);
  assert.match(backgroundSource, /acquireDescriptorBytes[\s\S]*fetch\s*\(/);
});

test('image transport keeps MAIN bytes behind bounded stores and maps frame crops by screen coordinates', () => {
  const backgroundSource = fs.readFileSync(path.join(extensionRoot, 'background.js'), 'utf8');
  const storeStart = backgroundSource.indexOf('function executeMainStoreStart');
  const screenshotStart = backgroundSource.indexOf('async function captureVisibleTabCrop');
  assert.ok(storeStart >= 0 && screenshotStart > storeStart);
  const storeSource = backgroundSource.slice(storeStart, screenshotStart);
  assert.match(storeSource, /return \{ storeID, byteCount: bytes\.byteLength, mimeType \}/);
  assert.doesNotMatch(storeSource, /return \{[^}]*\bbytes\s*:/);
  assert.match(backgroundSource, /finally[\s\S]*executeScriptAwait[\s\S]*stores\.delete/);
  assert.match(backgroundSource, /replayImageSessions/);
  assert.match(backgroundSource, /MAX_REPLAY_ATTEMPTS/);
  const contentSource = fs.readFileSync(path.join(extensionRoot, 'content.js'), 'utf8');
  assert.doesNotMatch(contentSource, /window\.frameElement|\.frameElement/);
  assert.match(contentSource, /screenRectFromPointerRect/);
  assert.match(contentSource, /readImageByteChunk/);
  assert.doesNotMatch(contentSource, /sendResponse\([^\n]*\bbytes\s*:/);
});

test('native drag finalization keeps sequence and wire fields as a Task4 contract', () => {
  const backgroundSource = fs.readFileSync(path.join(extensionRoot, 'background.js'), 'utf8');
  const contentSource = fs.readFileSync(path.join(extensionRoot, 'content.js'), 'utf8');
  assert.match(backgroundSource, /IMAGE_DRAG_WIRE_FIELDS/);
  assert.match(backgroundSource, /pendingPreviews/);
  assert.match(backgroundSource, /finalizeImageDrag/);
  assert.match(backgroundSource, /sequence: Number\(sequence\)/);
  assert.doesNotMatch(backgroundSource, /sequence:\s*Number\.isInteger\(Number\(response\.sequence\)\)[\s\S]*latestSequence/);
  assert.match(contentSource, /finalizeImageDrag/);
  assert.match(contentSource, /finalSequence/);
  assert.match(contentSource, /insidePet/);
  assert.match(contentSource, /mouthScreenPoint/);
});

test('screenshot crop asks top frame for metrics and clamps against actual screenshot pixels', () => {
  const backgroundSource = fs.readFileSync(path.join(extensionRoot, 'background.js'), 'utf8');
  const contentSource = fs.readFileSync(path.join(extensionRoot, 'content.js'), 'utf8');
  assert.match(backgroundSource, /getTopViewportMetrics/);
  assert.match(backgroundSource, /bitmap\.width[\s\S]*bitmap\.height/);
  assert.match(backgroundSource, /cropRectFromScreenRect/);
  assert.match(contentSource, /getTopViewportMetrics/);
  assert.match(contentSource, /naturalWidth[\s\S]*naturalHeight/);
  assert.doesNotMatch(contentSource, /window\.top\.innerWidth/);
});

test('content script does not read selection text during selectionchange', () => {
  const source = fs.readFileSync(path.join(extensionRoot, 'content.js'), 'utf8');
  assert.doesNotMatch(source, /selection\.(toString|textContent)\s*\(/);
  assert.match(source, /readSelectionAtClick\(/);
});

test('image capture does not request privileged browser bypass APIs or leak URL/bytes in logs', () => {
  for (const file of ['background.js', 'content.js', 'image-capture.js']) {
    const source = fs.readFileSync(path.join(extensionRoot, file), 'utf8');
    assert.doesNotMatch(source, /\bdebugger\b|chrome\.cookies|chrome\.history|tabs\.create\s*\(|tabs\.update\s*\(/);
    assert.doesNotMatch(source, /console\.(log|debug|info|warn|error)\s*\(/);
  }
});
