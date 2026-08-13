const test = require('node:test');
const assert = require('node:assert/strict');

const Capture = require('../image-capture.js');

test('frame byte store round-trips a multi-megabyte fixture through JSON-safe base64 chunks', () => {
  const source = Uint8Array.from({ length: (2 * 1024 * 1024) + 17 }, (_, index) => index % 251);
  const store = new Capture.FrameByteStore({ ttlMs: 300_000 });
  const started = store.start(source, { mimeType: 'image/png' });
  assert.deepEqual(Object.keys(started).sort(), ['byteCount', 'mimeType', 'storeID'].sort());
  const output = new Uint8Array(source.byteLength);
  let outputOffset = 0;
  for (let index = 0; index < Math.ceil(started.byteCount / Capture.IMAGE_CHUNK_BYTES); index += 1) {
    const response = JSON.parse(JSON.stringify(store.read(started.storeID, index)));
    assert.equal(response.bytes, undefined);
    assert.ok(JSON.stringify(response).length < Capture.IMAGE_FRAME_MAX_BYTES);
    const chunk = Capture.decodeBase64(response.base64Data);
    output.set(chunk, outputOffset);
    outputOffset += chunk.byteLength;
  }
  assert.deepEqual(output, source);
  assert.equal(store.release(started.storeID), true);
  assert.equal(store.read(started.storeID, 0), null);
});

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

test('srcset data URLs with commas remain one candidate', () => {
  const candidates = Capture.parseSrcset('data:image/svg+xml,%3Csvg%3E%3C/svg%3E 1x, https://example.test/high.png 2x');
  assert.equal(candidates.length, 2);
  assert.equal(candidates[0].url, 'data:image/svg+xml,%3Csvg%3E%3C/svg%3E');
});

test('srcset keeps a descriptorless candidate before a density candidate and data payload commas', () => {
  const mixed = Capture.parseSrcset('a.jpg, b.jpg 2x');
  assert.deepEqual(mixed.map((candidate) => candidate.url), ['a.jpg', 'b.jpg']);
  const data = Capture.parseSrcset('data:image/svg+xml,<svg>a,b</svg> 1x, https://example.test/high.png 2x');
  assert.deepEqual(data.map((candidate) => candidate.url), ['data:image/svg+xml,<svg>a,b</svg>', 'https://example.test/high.png']);
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

test('image message ledger requires the exact per-message ack and keeps end interim events pending', () => {
  const ledger = new Capture.ImageMessageLedger();
  ledger.begin({ captureID: 'one', messages: [{ type: 'imageBegin' }, { type: 'imageChunk' }, { type: 'imageEnd' }] });
  assert.deepEqual(ledger.next().message, { type: 'imageBegin' });
  assert.equal(ledger.receive({ captureID: 'other', type: 'ack' }), false);
  assert.equal(ledger.receive({ captureID: 'one', type: 'ack', code: 'image-chunk-accepted' }), false);
  assert.equal(ledger.receive({ captureID: 'one', type: 'ack', code: 'image-begin-accepted' }), true);
  assert.deepEqual(ledger.next().message, { type: 'imageChunk' });
  assert.equal(ledger.receive({ captureID: 'one', type: 'ack', code: 'image-begin-accepted' }), false);
  assert.equal(ledger.receive({ captureID: 'one', type: 'ack', code: 'image-chunk-accepted' }), true);
  assert.deepEqual(ledger.next().message, { type: 'imageEnd' });
  assert.equal(ledger.receive({ captureID: 'one', type: 'presented' }), true);
  assert.equal(ledger.pending.type, 'imageEnd');
  assert.equal(ledger.receive({ captureID: 'one', type: 'animate' }), true);
  assert.equal(ledger.pending.type, 'imageEnd');
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

test('dragend chooses native inside-pet drop and consumes late preview acknowledgements', () => {
  const hit = new Capture.DragSessionState('drag-hit');
  hit.start();
  const sequence = hit.preview({ x: 10, y: 20 });
  assert.equal(hit.consumePreviewAck({ captureID: 'drag-hit', type: 'imageDragPreviewAck', sequence: sequence.sequence, insidePet: true, mouthScreenPoint: { x: 4, y: 5 } }), true);
  assert.equal(hit.dragEnd(), 'drop');
  assert.equal(hit.consumePreviewAck({ captureID: 'drag-hit', type: 'imageDragPreviewAck', sequence: sequence.sequence + 1, insidePet: true }), false);

  const miss = new Capture.DragSessionState('drag-miss');
  miss.start();
  const missSequence = miss.preview({ x: 1, y: 2 });
  assert.equal(miss.consumePreviewAck({ captureID: 'drag-miss', type: 'imageDragPreviewAck', sequence: missSequence.sequence, insidePet: false }), true);
  assert.equal(miss.dragEnd(), 'cancel');
});

test('native final-hit decisions require the exact final sequence and reject out-of-order ACKs', () => {
  const state = new Capture.DragSessionState('drag-final');
  state.start();
  const first = state.preview({ x: 10, y: 20 });
  const second = state.preview({ x: 20, y: 30 });
  assert.equal(state.consumePreviewAck({ captureID: 'drag-final', type: 'imageDragPreviewAck', sequence: second.sequence, insidePet: true }), true);
  assert.equal(state.consumePreviewAck({ captureID: 'drag-final', type: 'imageDragPreviewAck', sequence: first.sequence, insidePet: false }), false);
  assert.equal(state.nativeInsidePet, true);
  const final = state.requestFinalize({ x: 40, y: 50 }, 100);
  assert.equal(final.sequence, second.sequence + 1);
  assert.equal(state.consumeFinalAck({ captureID: 'drag-final', type: 'imageDragPreviewAck', sequence: second.sequence, insidePet: false }, 120), null);
  assert.equal(state.consumeFinalAck({ captureID: 'drag-final', type: 'imageDragPreviewAck', sequence: final.sequence, insidePet: true, mouthScreenPoint: { x: 5, y: 6 } }, 130), 'drop');

  const miss = new Capture.DragSessionState('drag-final-miss');
  miss.start();
  const missFinal = miss.requestFinalize({ x: 1, y: 2 }, 200);
  assert.equal(miss.consumeFinalAck({ captureID: 'drag-final-miss', type: 'imageDragPreviewAck', sequence: missFinal.sequence, insidePet: false }, 210), 'cancel');

  const timeout = new Capture.DragSessionState('drag-final-timeout');
  timeout.start();
  timeout.requestFinalize({ x: 1, y: 2 }, 300);
  assert.equal(timeout.finalizeTimeout(1_101), 'cancel');
});

test('image transfer replay is capped at three attempts and expires after five minutes', () => {
  const replay = new Capture.ImageReplayController({ now: () => 1_000, maxAttempts: 3, ttlMs: 300_000 });
  replay.begin('one', [{ type: 'imageBegin' }, { type: 'imageChunk' }]);
  assert.equal(replay.replay(2).length, 2);
  assert.equal(replay.replay(3).length, 2);
  assert.equal(replay.replay(4).length, 2);
  assert.equal(replay.replay(5), null);
  assert.equal(replay.replay(301_001), null);
});

test('screen rect mapping handles negative displays and nested frame offsets without frameElement', () => {
  const rect = Capture.accumulateFrameCoordinates(
    { left: 4, top: 6, right: 104, bottom: 206 },
    [{ left: 20, top: 30 }, { left: -50, top: 10 }],
  );
  assert.deepEqual(rect, { left: -26, top: 46, right: 74, bottom: 246 });
  assert.deepEqual(Capture.cropRectFromScreenRect(
    { left: -100, top: 250, right: 100, bottom: 450 },
    { screenX: -200, screenY: 100, browserChromeHeight: 50 },
    2,
  ), { left: 200, top: 200, width: 400, height: 400 });
  assert.deepEqual(Capture.screenRectFromPointerRect(
    { left: 12, top: 18, right: 112, bottom: 218 },
    { clientX: 2, clientY: 8, screenX: -48, screenY: 108 },
  ), { left: -38, top: 118, right: 62, bottom: 318 });
  assert.deepEqual(Capture.cropRectFromScreenRect(
    { left: -300, top: 80, right: 200, bottom: 600 },
    { screenX: -200, screenY: 20, browserChromeHeight: 40, viewportWidth: 400, viewportHeight: 300 },
    2,
    { width: 800, height: 600 },
  ), { left: 0, top: 40, width: 800, height: 560 });
});
