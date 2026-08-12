(function exposeContentCore(global) {
  const FEED_BUTTON_DELAY_MS = 300;
  const FEED_BUTTON_TTL_MS = 5_000;
  function selectionPresence(selection, { restrictedPage = false, passwordField = false } = {}) {
    if (restrictedPage || passwordField || !selection || selection.isCollapsed || !selection.rangeCount) {
      return { show: false, range: null, rect: null };
    }
    const range = selection.getRangeAt(0).cloneRange();
    const rect = range.getBoundingClientRect();
    const hasGeometry = Boolean(rect && (rect.width || rect.height));
    return { show: hasGeometry, range, rect: hasGeometry ? rect : null };
  }

  function readSelectionAtClick(selection) {
    return selection && typeof selection.toString === 'function' ? selection.toString() : '';
  }

  function finitePositive(value, fallback = 1) {
    return Number.isFinite(Number(value)) && Number(value) > 0 ? Number(value) : fallback;
  }

  function mapScreenPointToViewport(screenPoint, windowMetrics = {}) {
    const coordinateScale = windowMetrics.screenCoordinatesArePhysicalPixels
      ? finitePositive(windowMetrics.devicePixelRatio)
      : finitePositive(windowMetrics.screenCoordinateScale, 1);
    const browserChromeHeight = Number.isFinite(Number(windowMetrics.browserChromeHeight))
      ? Math.max(0, Number(windowMetrics.browserChromeHeight))
      : Math.max(0, (Number(windowMetrics.outerHeight) || 0) - (Number(windowMetrics.innerHeight) || 0));
    // screenX/screenY and event.screenX/screenY are CSS/global coordinates. DPR and visual zoom
    // are validated above but are not applied again unless the caller explicitly marks screen
    // coordinates as physical pixels, avoiding double scaling on Retina/zoomed pages.
    const visualViewportOffsetX = Number(windowMetrics.visualViewportOffsetX) || 0;
    const visualViewportOffsetY = Number(windowMetrics.visualViewportOffsetY) || 0;
    return {
      x: Math.round((Number(screenPoint.x) - Number(windowMetrics.screenX || 0)) / coordinateScale - visualViewportOffsetX),
      y: Math.round((Number(screenPoint.y) - Number(windowMetrics.screenY || 0) - browserChromeHeight) / coordinateScale - visualViewportOffsetY),
    };
  }

  function flightKeyframes(start, end, steps = 8) {
    const count = Math.max(2, Math.floor(Number(steps) || 2));
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const distance = Math.hypot(dx, dy);
    const control = { x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - Math.min(120, distance * 0.35) };
    return Array.from({ length: count }, (_, index) => {
      const t = index / (count - 1);
      const inverse = 1 - t;
      return {
        point: {
          x: Math.round(inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x),
          y: Math.round(inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y),
        },
        scale: 1 - 0.55 * t,
        opacity: 1 - 0.18 * t,
      };
    });
  }

  const api = { FEED_BUTTON_DELAY_MS, FEED_BUTTON_TTL_MS, selectionPresence, readSelectionAtClick, mapScreenPointToViewport, flightKeyframes };
  global.PromptStudioContentCore = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
}(typeof globalThis !== 'undefined' ? globalThis : this));
