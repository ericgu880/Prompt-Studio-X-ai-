const test = require('node:test');
const assert = require('node:assert/strict');
const {
  CAPTURE_TTL_MS,
  MAX_RETRY_ATTEMPTS,
  PendingCaptureLedger,
  isTerminalCaptureType,
  captureRoute,
} = require('../background-logic.js');

test('presented and animate keep pending captures while terminal responses clear them', () => {
  const ledger = new PendingCaptureLedger({ now: 1000 });
  ledger.add({ captureID: 'one', selectedText: 'hello' }, 7);
  assert.equal(isTerminalCaptureType('presented'), false);
  assert.equal(isTerminalCaptureType('animate'), false);
  assert.equal(ledger.receive({ type: 'presented', captureID: 'one' }, 1200), true);
  assert.equal(ledger.has('one'), true);
  assert.equal(ledger.receive({ type: 'animate', captureID: 'one' }, 1300), true);
  assert.equal(ledger.has('one'), true);
  assert.equal(ledger.receive({ type: 'saved', captureID: 'one' }, 1400), true);
  assert.equal(ledger.has('one'), false);
});

test('disconnect replay retries pending captures by ID with TTL and a finite retry cap', () => {
  assert.equal(CAPTURE_TTL_MS, 300_000);
  const ledger = new PendingCaptureLedger({ now: 0 });
  ledger.add({ captureID: 'one', selectedText: 'hello' }, 7);
  for (let attempt = 0; attempt < MAX_RETRY_ATTEMPTS; attempt += 1) {
    const replay = ledger.replayable(100 + attempt);
    assert.equal(replay.length, attempt < MAX_RETRY_ATTEMPTS ? 1 : 0);
    if (replay.length) ledger.markSent('one', 100 + attempt);
  }
  assert.equal(ledger.replayable(500).length, 0);
  ledger.add({ captureID: 'expired', selectedText: 'bye' }, 8, 0);
  assert.equal(ledger.replayable(CAPTURE_TTL_MS + 1).length, 0);
  ledger.expire(CAPTURE_TTL_MS + 1);
  assert.equal(ledger.has('expired'), false);
});

test('capture response routing preserves the originating frame and rejects unknown IDs', () => {
  const entries = new Map([['image-1', { tabID: 11, frameID: 7 }]]);
  assert.deepEqual(captureRoute(entries, { captureID: 'image-1', type: 'saved' }), { tabID: 11, frameID: 7 });
  assert.equal(captureRoute(entries, { captureID: 'other', type: 'saved' }), null);
  assert.equal(captureRoute(entries, { captureID: 'image-1', type: 'saved' }).frameID, 7);
});
