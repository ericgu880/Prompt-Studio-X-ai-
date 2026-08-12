/* Pure selection, metadata, coordinate, and reconnect helpers shared by the content script and Node tests. */
(function exposeSelectionHelpers(global) {
  const MAX_CAPTURE_CHARACTERS = 50_000;
  const FEED_BUTTON_SIZE = 28;

  function selectionDecision({ textLength = 0, collapsed = false, passwordField = false, restrictedPage = false } = {}) {
    return !collapsed && textLength > 0 && !passwordField && !restrictedPage ? 'show' : 'hide';
  }

  function feedButtonPosition(rect, viewport) {
    const maxLeft = Math.max(0, viewport.width - FEED_BUTTON_SIZE);
    const maxTop = Math.max(0, viewport.height - FEED_BUTTON_SIZE);
    const preferredLeft = Number(rect.right) + 8;
    const preferredTop = Number(rect.top) - 4;
    return {
      left: Math.min(maxLeft, Math.max(0, Number.isFinite(preferredLeft) ? preferredLeft : 0)),
      top: Math.min(maxTop, Math.max(0, Number.isFinite(preferredTop) ? preferredTop : 0)),
    };
  }

  function mapScreenPointToViewport(screenPoint, windowMetrics) {
    const coordinateScale = windowMetrics.screenCoordinatesArePhysicalPixels
      ? (Number.isFinite(Number(windowMetrics.devicePixelRatio)) && Number(windowMetrics.devicePixelRatio) > 0 ? Number(windowMetrics.devicePixelRatio) : 1)
      : (Number.isFinite(Number(windowMetrics.screenCoordinateScale)) && Number(windowMetrics.screenCoordinateScale) > 0 ? Number(windowMetrics.screenCoordinateScale) : 1);
    const browserChromeHeight = Number.isFinite(Number(windowMetrics.browserChromeHeight))
      ? Math.max(0, Number(windowMetrics.browserChromeHeight))
      : Math.max(0, (Number(windowMetrics.outerHeight) || 0) - (Number(windowMetrics.innerHeight) || 0));
    const visualViewportOffsetX = Number(windowMetrics.visualViewportOffsetX) || 0;
    const visualViewportOffsetY = Number(windowMetrics.visualViewportOffsetY) || 0;
    return {
      x: Math.round((Number(screenPoint.x) - Number(windowMetrics.screenX)) / coordinateScale - visualViewportOffsetX),
      y: Math.round((Number(screenPoint.y) - Number(windowMetrics.screenY) - browserChromeHeight) / coordinateScale - visualViewportOffsetY),
    };
  }

  function captureLengthMessage(value) {
    const length = typeof value === 'string' ? value.length : 0;
    return length > MAX_CAPTURE_CHARACTERS
      ? '所选内容超过 50,000 个字符，无法采集。请缩小选区后重试。'
      : null;
  }

  function siteNameFromURL(pageURL) {
    try {
      return new URL(pageURL).hostname;
    } catch {
      return '';
    }
  }

  function newCaptureID() {
    if (global.crypto && typeof global.crypto.randomUUID === 'function') {
      return global.crypto.randomUUID();
    }
    return `capture-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  }

  function makeCaptureCandidate({ text, pageTitle, pageURL, clickScreenPoint, capturedAt, captureID } = {}) {
    const normalizedText = typeof text === 'string' ? text.trim() : '';
    if (!normalizedText) throw new Error('empty-selection');
    if (normalizedText.length > MAX_CAPTURE_CHARACTERS) throw new Error('selection-too-large');
    return {
      captureID: captureID || newCaptureID(),
      selectedText: normalizedText,
      pageTitle: typeof pageTitle === 'string' ? pageTitle : '',
      pageURL: typeof pageURL === 'string' ? pageURL : '',
      siteName: siteNameFromURL(pageURL),
      clickScreenPoint: {
        x: Number(clickScreenPoint && clickScreenPoint.x) || 0,
        y: Number(clickScreenPoint && clickScreenPoint.y) || 0,
      },
      capturedAt: capturedAt || new Date().toISOString(),
    };
  }

  function nextReconnectDelay(attempt) {
    const safeAttempt = Math.max(0, Number(attempt) || 0);
    return Math.min(5_000, 100 * (2 ** safeAttempt));
  }

  const api = {
    MAX_CAPTURE_CHARACTERS,
    FEED_BUTTON_SIZE,
    selectionDecision,
    feedButtonPosition,
    mapScreenPointToViewport,
    captureLengthMessage,
    siteNameFromURL,
    makeCaptureCandidate,
    nextReconnectDelay,
  };

  global.PromptStudioSelection = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
}(typeof globalThis !== 'undefined' ? globalThis : this));
