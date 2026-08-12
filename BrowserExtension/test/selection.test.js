const test = require('node:test');
const assert = require('node:assert/strict');

const {
  MAX_CAPTURE_CHARACTERS,
  FEED_BUTTON_SIZE,
  selectionDecision,
  feedButtonPosition,
  mapScreenPointToViewport,
  captureLengthMessage,
  siteNameFromURL,
  makeCaptureCandidate,
  nextReconnectDelay,
} = require('../selection.js');

test('selectionDecision only shows the feed button for a usable web selection', () => {
  assert.equal(selectionDecision({ textLength: 3, collapsed: false, passwordField: false, restrictedPage: false }), 'show');
  assert.equal(selectionDecision({ textLength: 0, collapsed: true, passwordField: false, restrictedPage: false }), 'hide');
  assert.equal(selectionDecision({ textLength: 4, collapsed: false, passwordField: true, restrictedPage: false }), 'hide');
  assert.equal(selectionDecision({ textLength: 4, collapsed: false, passwordField: false, restrictedPage: true }), 'hide');
});

test('feedButtonPosition stays inside the viewport and uses a 28px button', () => {
  const position = feedButtonPosition({ left: 2, right: 6, top: 1, bottom: 5 }, { width: 320, height: 180 });
  assert.equal(FEED_BUTTON_SIZE, 28);
  assert.ok(position.left >= 0 && position.top >= 0);
  assert.ok(position.left + FEED_BUTTON_SIZE <= 320);
  assert.ok(position.top + FEED_BUTTON_SIZE <= 180);
});

test('screen coordinates map back to viewport coordinates after the app returns a mouth point', () => {
  assert.deepEqual(
    mapScreenPointToViewport(
      { x: 1410, y: 290 },
      { screenX: 1280, screenY: 100, visualViewportOffsetX: 12, visualViewportOffsetY: 8 },
    ),
    { x: 118, y: 182 },
  );
});

test('captureLengthMessage gives a frontend warning at the 50,000 character limit', () => {
  assert.equal(MAX_CAPTURE_CHARACTERS, 50_000);
  assert.equal(captureLengthMessage('a'.repeat(50_000)), null);
  assert.match(captureLengthMessage('a'.repeat(50_001)), /50,000/);
});

test('candidate metadata is read only when the click builds the candidate', () => {
  const candidate = makeCaptureCandidate({
    text: '  selected prompt  ',
    pageTitle: 'A page',
    pageURL: 'https://example.test/path?q=1',
    clickScreenPoint: { x: 20, y: 30 },
    capturedAt: '2026-08-12T00:00:00.000Z',
    captureID: 'capture-1',
  });
  assert.deepEqual(candidate, {
    captureID: 'capture-1',
    selectedText: '  selected prompt  ',
    pageTitle: 'A page',
    pageURL: 'https://example.test/path?q=1',
    siteName: 'example.test',
    clickScreenPoint: { x: 20, y: 30 },
    capturedAt: '2026-08-12T00:00:00.000Z',
  });
});

test('siteNameFromURL does not leak URL paths or query strings', () => {
  assert.equal(siteNameFromURL('https://docs.example.test/a?secret=1#fragment'), 'docs.example.test');
  assert.equal(siteNameFromURL('not a URL'), '');
});

test('native reconnect delay is bounded and increases between attempts', () => {
  assert.equal(nextReconnectDelay(0), 100);
  assert.equal(nextReconnectDelay(1), 200);
  assert.equal(nextReconnectDelay(10), 5_000);
  assert.equal(nextReconnectDelay(99), 5_000);
});
