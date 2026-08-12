const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  selectionPresence,
  readSelectionAtClick,
  mapScreenPointToViewport,
  flightKeyframes,
  shouldAnimateCaptureResponse,
  FEED_BUTTON_DELAY_MS,
  FEED_BUTTON_TTL_MS,
} = require('../content-core.js');

test('selection overlay uses the requested 300ms delay and five second expiry', () => {
  assert.equal(FEED_BUTTON_DELAY_MS, 300);
  assert.equal(FEED_BUTTON_TTL_MS, 5_000);
});

test('selectionchange presence check never reads selected body text', () => {
  let reads = 0;
  const selection = {
    isCollapsed: false,
    rangeCount: 1,
    getRangeAt() {
      return {
        cloneRange: () => ({ getBoundingClientRect: () => ({ left: 5, right: 25, top: 10, width: 20, height: 16 }) }),
      };
    },
    toString() {
      reads += 1;
      return 'secret selected body';
    },
  };
  assert.equal(selectionPresence(selection, { restrictedPage: false, passwordField: false }).show, true);
  assert.equal(reads, 0);
});

test('password and restricted selections never become feed candidates', () => {
  const selection = {
    isCollapsed: false,
    rangeCount: 1,
    getRangeAt() {
      return { cloneRange: () => ({ getBoundingClientRect: () => ({ width: 20, height: 16 }) }) };
    },
  };
  assert.equal(selectionPresence(selection, { passwordField: true }).show, false);
  assert.equal(selectionPresence(selection, { restrictedPage: true }).show, false);
});

test('click seam reads selection text exactly at click time', () => {
  let reads = 0;
  const selection = { toString: () => { reads += 1; return 'approved text'; } };
  assert.equal(readSelectionAtClick(selection), 'approved text');
  assert.equal(reads, 1);
});

test('screen-to-viewport mapping handles browser chrome, zoom, DPR and negative displays', () => {
  assert.deepEqual(
    mapScreenPointToViewport(
      { x: -1260, y: 160 },
      {
        screenX: -1440,
        screenY: 100,
        outerHeight: 900,
        innerHeight: 800,
        visualViewportOffsetX: 24,
        visualViewportOffsetY: 12,
        visualViewportScale: 1.25,
        devicePixelRatio: 2,
        screenCoordinatesArePhysicalPixels: false,
      },
    ),
    { x: 156, y: -52 },
  );
});

test('physical screen coordinates use DPR exactly once', () => {
  assert.deepEqual(
    mapScreenPointToViewport(
      { x: 220, y: 180 },
      {
        screenX: 100,
        screenY: 50,
        browserChromeHeight: 10,
        devicePixelRatio: 2,
        screenCoordinatesArePhysicalPixels: true,
      },
    ),
    { x: 60, y: 60 },
  );
});

test('text flight starts at the saved selection point and follows a shrinking arc to the mouth', () => {
  const frames = flightKeyframes({ x: 40, y: 80 }, { x: 240, y: 180 }, 5);
  assert.equal(frames.length, 5);
  assert.deepEqual(frames[0].point, { x: 40, y: 80 });
  assert.deepEqual(frames.at(-1).point, { x: 240, y: 180 });
  assert.ok(frames[1].point.y < 130);
  assert.ok(frames[0].scale > frames.at(-1).scale);
});

test('animate plus saved produces one text flight while saved alone remains a fallback', () => {
  const animated = new Set();
  assert.equal(shouldAnimateCaptureResponse('animate', 'capture-1', animated), true);
  assert.equal(shouldAnimateCaptureResponse('saved', 'capture-1', animated), false);
  assert.equal(shouldAnimateCaptureResponse('saved', 'capture-2', animated), true);
  assert.equal(shouldAnimateCaptureResponse('failed', 'capture-3', animated), false);
});

test('scroll, resize, and outside pointer events clear transient selection UI', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'content.js'), 'utf8');
  assert.match(source, /window\.addEventListener\('scroll', clearSelectionUI/);
  assert.match(source, /window\.addEventListener\('resize', clearSelectionUI/);
  assert.match(source, /event\.target !== feedButton/);
  assert.match(source, /result\.type === 'cancelled'/);
  assert.match(source, /result\.clearSource/);
  assert.match(source, /removeAllRanges\(\)/);
});
