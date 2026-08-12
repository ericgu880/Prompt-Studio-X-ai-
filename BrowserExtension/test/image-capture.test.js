const test = require('node:test');
const assert = require('node:assert/strict');

const Capture = require('../image-capture.js');

test('srcset parser chooses the highest usable width/density and currentSrc wins', () => {
  const candidates = Capture.parseSrcset('small.jpg 320w, medium.jpg 2x, large.jpg 1280w, invalid.jpg nope');
  assert.deepEqual(candidates.map((candidate) => candidate.url), ['small.jpg', 'medium.jpg', 'large.jpg']);
  assert.equal(Capture.selectSrcsetCandidate(candidates, { viewportWidth: 800, devicePixelRatio: 1 }).url, 'medium.jpg');
  assert.equal(Capture.selectImageURL({ currentSrc: 'current.jpg', src: 'fallback.jpg', srcset: 'large.jpg 1280w' }), 'current.jpg');
});

test('DOM metadata resolves data, blob, canvas, inline SVG, and only valid CSS background layers', () => {
  assert.equal(Capture.classifyImageSource('data:image/png;base64,AA==').domSourceKind, 'dataURL');
  assert.equal(Capture.classifyImageSource('blob:https://example.test/id').domSourceKind, 'blob');
  assert.equal(Capture.classifyImageSource('https://example.test/a.png').domSourceKind, 'image');
  assert.equal(Capture.parseCSSBackgroundImages('linear-gradient(red, blue), url("/first.png"), url(/second.png)')[0], '/first.png');
  assert.deepEqual(Capture.cropRectForVisibleElement({ left: -20, top: 12, right: 140, bottom: 220 }, { width: 100, height: 180 }, 2), {
    left: 0, top: 24, width: 200, height: 336,
  });
  const backgroundElement = {
    tagName: 'div',
    computedStyle: { backgroundImage: 'url("/top.png"), url("/under.png")' },
  };
  assert.deepEqual(Capture.selectDOMImageMetadata(backgroundElement, { allowCSSBackground: true }).backgroundLayers, ['/top.png', '/under.png']);
});

test('image metadata preserves candidate fields and marks screenshot fallback', () => {
  const candidate = Capture.makeImageCandidate({
    captureID: 'image-1', pageTitle: 'Page', pageURL: 'https://example.test/page', siteName: 'example.test',
    resourceURL: 'https://cdn.example.test/a.png?token=1#fragment', altText: 'alt', originalFileName: 'a.png',
    domSourceKind: 'cssBackground', acquisitionMethod: 'screenshot', isScreenshot: true,
    mimeType: 'image/png', byteCount: 12, sha256: 'a'.repeat(64), pixelWidth: 200, pixelHeight: 100,
    clickScreenPoint: { x: 10, y: 20 }, capturedAt: '2026-08-13T00:00:00.000Z',
  });
  assert.deepEqual(candidate, {
    captureID: 'image-1', pageTitle: 'Page', pageURL: 'https://example.test/page', siteName: 'example.test',
    resourceURL: 'https://cdn.example.test/a.png?token=1', altText: 'alt', originalFileName: 'a.png',
    domSourceKind: 'cssBackground', acquisitionMethod: 'screenshot', isScreenshot: true,
    mimeType: 'image/png', byteCount: 12, sha256: 'a'.repeat(64), pixelWidth: 200, pixelHeight: 100,
    clickScreenPoint: { x: 10, y: 20 }, capturedAt: '2026-08-13T00:00:00.000Z',
  });
});

test('acquisition tries page context then extension fetch then loaded bytes then screenshot', async () => {
  const calls = [];
  const result = await Capture.acquireImageBytes({ url: 'https://example.test/image.png', loadedBytes: Uint8Array.from([9]) }, {
    pageContextFetch: async () => { calls.push('page'); return null; },
    extensionFetch: async () => { calls.push('extension'); return null; },
    loadedBytes: async () => { calls.push('loaded'); return Uint8Array.from([1, 2, 3]); },
    screenshot: async () => { calls.push('screenshot'); return Uint8Array.from([4]); },
  });
  assert.deepEqual(calls, ['page', 'extension', 'loaded']);
  assert.deepEqual([...result.bytes], [1, 2, 3]);
  assert.equal(result.acquisitionMethod, 'loadedBytes');
});

test('acquisition falls back to screenshot only after all dedicated acquisition paths fail', async () => {
  const calls = [];
  const result = await Capture.acquireImageBytes({ url: 'https://example.test/image.png' }, {
    pageContextFetch: async () => { calls.push('page'); return null; },
    extensionFetch: async () => { calls.push('extension'); return null; },
    loadedBytes: async () => { calls.push('loaded'); return null; },
    screenshot: async () => { calls.push('screenshot'); return Uint8Array.from([4]); },
  });
  assert.deepEqual(calls, ['page', 'extension', 'loaded', 'screenshot']);
  assert.equal(result.acquisitionMethod, 'screenshot');
  assert.equal(result.isScreenshot, true);
});

test('sha256 and raw 512KiB chunks never exceed the 50MiB limit', async () => {
  const bytes = new Uint8Array(512 * 1024 + 3);
  const digest = await Capture.sha256Hex(bytes);
  assert.match(digest, /^[0-9a-f]{64}$/);
  const chunks = Capture.imageChunks(bytes);
  assert.equal(chunks.length, 2);
  assert.equal(chunks[0].index, 0);
  assert.equal(Capture.decodeBase64(chunks[0].base64Data).byteLength, 512 * 1024);
  assert.throws(() => Capture.imageChunks(new Uint8Array(Capture.MAX_IMAGE_BYTES + 1)), /50 MiB/);
});

test('wire builder emits origin on every image message and keeps terminal imageEnd routing', () => {
  const messages = Capture.buildImageMessages({
    origin: 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/',
    candidate: { captureID: 'image-1', byteCount: 3, sha256: 'b'.repeat(64) },
    bytes: Uint8Array.from([1, 2, 3]),
  });
  assert.deepEqual(messages.map((message) => message.type), ['imageBegin', 'imageChunk', 'imageEnd']);
  assert.ok(messages.every((message) => message.origin));
  assert.equal(messages.at(-1).captureID, 'image-1');
  assert.equal(messages.at(-1).byteCount, 3);
});

test('image message ledger requires an ack for each message and routes by capture ID', () => {
  const ledger = new Capture.ImageMessageLedger();
  ledger.begin({ captureID: 'one', messages: [{ type: 'imageBegin' }, { type: 'imageChunk' }, { type: 'imageEnd' }] });
  assert.deepEqual(ledger.next().message, { type: 'imageBegin' });
  assert.equal(ledger.receive({ captureID: 'other', type: 'ack' }), false);
  assert.equal(ledger.receive({ captureID: 'one', type: 'ack' }), true);
  assert.deepEqual(ledger.next().message, { type: 'imageChunk' });
  assert.equal(ledger.receive({ captureID: 'one', type: 'ack' }), true);
  assert.deepEqual(ledger.next().message, { type: 'imageEnd' });
  assert.equal(ledger.receive({ captureID: 'one', type: 'saved' }), true);
  assert.equal(ledger.done, true);
});

test('drag state cancels unfinished sessions, honors reduced motion, and renders only when inside pet', () => {
  const state = new Capture.DragSessionState('drag-1');
  assert.equal(state.start(), true);
  assert.equal(state.preview({ x: 10, y: 20 }).x, 10);
  assert.equal(state.feedback({ insidePet: true, mouthScreenPoint: { x: 2, y: 3 } }).insidePet, true);
  assert.equal(state.drop(), true);
  assert.equal(state.end(), false);
  const cancelled = new Capture.DragSessionState('drag-2');
  cancelled.start();
  assert.equal(cancelled.end(), 'cancel');
  assert.equal(Capture.shouldReduceMotion(() => true), true);
});
