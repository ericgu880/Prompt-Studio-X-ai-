(function runPromptStudioContent() {
  const S = globalThis.PromptStudioSelection;
  const C = globalThis.PromptStudioContentCore;
  if (!S || !C || !document.body) return;

  const restrictedPage = !['http:', 'https:'].includes(location.protocol);
  let feedButton = null;
  let notice = null;
  let selectionTimer = null;
  let removeTimer = null;
  let selectionRange = null;
  let selectionRect = null;
  const captureOrigins = new Map();
  const animatedCaptureIDs = new Set();

  function isPasswordNode(node) {
    const element = node && (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement);
    if (!element) return false;
    const field = element.closest('input, textarea, [contenteditable="true"]');
    if (!field) return false;
    return field.matches('input[type="password"], textarea[type="password"]')
      || (field.tagName === 'INPUT' && field.type === 'password');
  }

  function isPasswordSelection(selection) {
    return isPasswordNode(selection.anchorNode)
      || isPasswordNode(selection.focusNode)
      || isPasswordNode(document.activeElement);
  }

  function clearSelectionUI() {
    if (selectionTimer) clearTimeout(selectionTimer);
    if (removeTimer) clearTimeout(removeTimer);
    selectionTimer = null;
    removeTimer = null;
    selectionRange = null;
    selectionRect = null;
    if (feedButton) {
      feedButton.remove();
      feedButton = null;
    }
  }

  function showNotice(message, anchor) {
    if (notice) notice.remove();
    notice = document.createElement('div');
    notice.id = 'promptstudio-capture-notice';
    notice.textContent = message;
    notice.style.left = `${Math.max(8, Math.min(window.innerWidth - 328, anchor.left))}px`;
    notice.style.top = `${Math.max(8, Math.min(window.innerHeight - 52, anchor.top + 34))}px`;
    document.documentElement.appendChild(notice);
    setTimeout(() => {
      if (notice) {
        notice.remove();
        notice = null;
      }
    }, 5_000);
  }

  function appendFeedButton(rect) {
    if (feedButton) feedButton.remove();
    feedButton = document.createElement('button');
    feedButton.id = 'promptstudio-capture-feed-button';
    feedButton.type = 'button';
    feedButton.setAttribute('aria-label', '采集到 PromptStudio');
    feedButton.textContent = '＋';
    const position = S.feedButtonPosition(rect, { width: window.innerWidth, height: window.innerHeight });
    feedButton.style.left = `${position.left}px`;
    feedButton.style.top = `${position.top}px`;
    feedButton.addEventListener('click', captureSelection, { once: true });
    feedButton.addEventListener('pointerdown', (event) => event.stopPropagation());
    document.documentElement.appendChild(feedButton);
    removeTimer = setTimeout(clearSelectionUI, C.FEED_BUTTON_TTL_MS);
  }

  function scheduleSelection() {
    if (restrictedPage) return clearSelectionUI();
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || isPasswordSelection(selection)) return clearSelectionUI();
    const range = selection.rangeCount ? selection.getRangeAt(0).cloneRange() : null;
    const rect = range && range.getBoundingClientRect();
    if (!range || !rect || !rect.width && !rect.height) return clearSelectionUI();
    const presence = C.selectionPresence(selection, {
      passwordField: isPasswordSelection(selection),
      restrictedPage,
    });
    if (!presence.show) return clearSelectionUI();
    selectionRange = presence.range;
    selectionRect = presence.rect;
    if (selectionTimer) clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => appendFeedButton(rect), C.FEED_BUTTON_DELAY_MS);
  }

  function captureSelection(event) {
    if (!selectionRange || !selectionRect) return;
    const selection = window.getSelection();
    const text = C.readSelectionAtClick(selection);
    const warning = S.captureLengthMessage(text);
    if (warning) {
      showNotice(warning, S.feedButtonPosition(selectionRect, { width: window.innerWidth, height: window.innerHeight }));
      clearSelectionUI();
      return;
    }
    let candidate;
    try {
      candidate = S.makeCaptureCandidate({
        text,
        pageTitle: document.title,
        pageURL: location.href,
        clickScreenPoint: { x: event.screenX, y: event.screenY },
        capturedAt: new Date().toISOString(),
      });
    } catch {
      clearSelectionUI();
      return;
    }
    const buttonRect = feedButton ? feedButton.getBoundingClientRect() : selectionRect;
    captureOrigins.set(candidate.captureID, {
      x: Number.isFinite(event.clientX) ? event.clientX : (buttonRect.left + buttonRect.width / 2),
      y: Number.isFinite(event.clientY) ? event.clientY : (buttonRect.top + buttonRect.height / 2),
    });
    clearSelectionUI();
    chrome.runtime.sendMessage({ type: 'captureCandidate', candidate }, (response) => {
      if (chrome.runtime.lastError || !response || !response.ok) {
        showNotice('PromptStudio 暂时不可用，请稍后重试。', { left: event.clientX, top: event.clientY });
      }
    });
  }

  function animateTextFlight(text, mouthScreenPoint, messageCaptureID) {
    if (!mouthScreenPoint || !text) return;
    const point = C.mapScreenPointToViewport(mouthScreenPoint, {
      screenX: window.screenX,
      screenY: window.screenY,
      outerHeight: window.outerHeight,
      innerHeight: window.innerHeight,
      visualViewportOffsetX: globalThis.visualViewport ? visualViewport.offsetLeft : 0,
      visualViewportOffsetY: globalThis.visualViewport ? visualViewport.offsetTop : 0,
      visualViewportScale: globalThis.visualViewport ? visualViewport.scale : 1,
      devicePixelRatio: window.devicePixelRatio,
      screenCoordinatesArePhysicalPixels: false,
    });
    const origin = captureOrigins.get(messageCaptureID) || { x: point.x, y: point.y };
    const fragment = document.createElement('div');
    fragment.className = 'promptstudio-capture-flight';
    fragment.textContent = text.slice(0, 180);
    fragment.style.left = `${Math.max(0, Math.min(window.innerWidth - 260, origin.x))}px`;
    fragment.style.top = `${Math.max(0, Math.min(window.innerHeight - 40, origin.y))}px`;
    document.documentElement.appendChild(fragment);
    const reduceMotion = globalThis.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduceMotion || typeof fragment.animate !== 'function') {
      setTimeout(() => fragment.remove(), 300);
      return;
    }
    const frames = C.flightKeyframes({ x: origin.x, y: origin.y }, point, 8);
    fragment.animate(frames.map((frame) => ({
      opacity: frame.opacity,
      transform: `translate(${frame.point.x - origin.x}px, ${frame.point.y - origin.y}px) scale(${frame.scale})`,
    })), { duration: 620, easing: 'cubic-bezier(.22,.8,.32,1)', fill: 'forwards' }).finished
      .then(() => fragment.remove(), () => fragment.remove());
  }

  chrome.runtime.onMessage.addListener((message) => {
    if (!message || message.type !== 'captureResult') return;
    const result = message.result || {};
    const messageCaptureID = result.captureID;
    if ((result.type === 'saved' || result.type === 'animate')
        && result.mouthScreenPoint
        && C.shouldAnimateCaptureResponse(result.type, messageCaptureID, animatedCaptureIDs)) {
      animateTextFlight(result.selectedText || result.text || '', result.mouthScreenPoint, messageCaptureID);
      if (result.type === 'saved') captureOrigins.delete(messageCaptureID);
    } else if (result.type === 'failed') {
      C.shouldAnimateCaptureResponse(result.type, messageCaptureID, animatedCaptureIDs);
      const failureCode = result.code || result.message || '';
      showNotice(failureCode === 'selection-too-large' ? '所选内容超过 50,000 个字符。' : '采集失败，请重试。', { left: 12, top: 12 });
      captureOrigins.delete(messageCaptureID);
    } else if (result.type === 'cancelled') {
      C.shouldAnimateCaptureResponse(result.type, messageCaptureID, animatedCaptureIDs);
      captureOrigins.delete(messageCaptureID);
    } else if (result.type === 'saved') {
      C.shouldAnimateCaptureResponse(result.type, messageCaptureID, animatedCaptureIDs);
      captureOrigins.delete(messageCaptureID);
    }
  });

  document.addEventListener('selectionchange', scheduleSelection, true);
  window.addEventListener('scroll', clearSelectionUI, true);
  window.addEventListener('resize', clearSelectionUI, true);
  document.addEventListener('pointerdown', (event) => {
    if (feedButton && event.target !== feedButton && !feedButton.contains(event.target)) clearSelectionUI();
  }, true);
}());
