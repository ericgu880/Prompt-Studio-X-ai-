(function runPromptStudioContent() {
  const S = globalThis.PromptStudioSelection;
  if (!S || !document.body) return;

  const restrictedPage = !['http:', 'https:'].includes(location.protocol);
  let feedButton = null;
  let notice = null;
  let selectionTimer = null;
  let removeTimer = null;
  let selectionRange = null;
  let selectionRect = null;
  let selectionTextLength = 0;

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
    selectionTextLength = 0;
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
    removeTimer = setTimeout(clearSelectionUI, 5_000);
  }

  function scheduleSelection() {
    if (restrictedPage) return clearSelectionUI();
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || isPasswordSelection(selection)) return clearSelectionUI();
    const range = selection.rangeCount ? selection.getRangeAt(0).cloneRange() : null;
    const rect = range && range.getBoundingClientRect();
    if (!range || !rect || !rect.width && !rect.height) return clearSelectionUI();
    const text = selection.toString();
    selectionTextLength = text.trim().length;
    if (S.selectionDecision({
      textLength: selectionTextLength,
      collapsed: selection.isCollapsed,
      passwordField: isPasswordSelection(selection),
      restrictedPage,
    }) === 'hide') return clearSelectionUI();
    selectionRange = range;
    selectionRect = rect;
    if (selectionTimer) clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => appendFeedButton(rect), 300);
  }

  function captureSelection(event) {
    if (!selectionRange || !selectionRect) return;
    const text = selectionRange.toString();
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
    clearSelectionUI();
    chrome.runtime.sendMessage({ type: 'captureCandidate', candidate }, (response) => {
      if (chrome.runtime.lastError || !response || !response.ok) {
        showNotice('PromptStudio 暂时不可用，请稍后重试。', { left: event.clientX, top: event.clientY });
      }
    });
  }

  function animateTextFlight(text, mouthScreenPoint) {
    if (!mouthScreenPoint || !text) return;
    const point = S.mapScreenPointToViewport(mouthScreenPoint, {
      screenX: window.screenX,
      screenY: window.screenY,
      visualViewportOffsetX: globalThis.visualViewport ? visualViewport.offsetLeft : 0,
      visualViewportOffsetY: globalThis.visualViewport ? visualViewport.offsetTop : 0,
    });
    const fragment = document.createElement('div');
    fragment.className = 'promptstudio-capture-flight';
    fragment.textContent = text.slice(0, 180);
    fragment.style.left = `${Math.max(0, Math.min(window.innerWidth - 260, point.x))}px`;
    fragment.style.top = `${Math.max(0, Math.min(window.innerHeight - 40, point.y))}px`;
    document.documentElement.appendChild(fragment);
    const reduceMotion = globalThis.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduceMotion || typeof fragment.animate !== 'function') {
      setTimeout(() => fragment.remove(), 300);
      return;
    }
    fragment.animate([
      { opacity: 1, transform: 'translate(0, 0) scale(1)' },
      { opacity: 0, transform: 'translate(0, -12px) scale(0.6)' },
    ], { duration: 620, easing: 'cubic-bezier(.22,.8,.32,1)', fill: 'forwards' }).finished
      .then(() => fragment.remove(), () => fragment.remove());
  }

  chrome.runtime.onMessage.addListener((message) => {
    if (!message || message.type !== 'captureResult') return;
    const result = message.result || {};
    if ((result.type === 'saved' || result.type === 'animate') && result.mouthScreenPoint) {
      animateTextFlight(result.selectedText || result.text || '', result.mouthScreenPoint);
    } else if (result.type === 'failed' && (result.code || result.message)) {
      const failureCode = result.code || result.message;
      showNotice(failureCode === 'selection-too-large' ? '所选内容超过 50,000 个字符。' : '采集失败，请重试。', { left: 12, top: 12 });
    }
  });

  document.addEventListener('selectionchange', scheduleSelection, true);
  window.addEventListener('scroll', clearSelectionUI, true);
  window.addEventListener('resize', clearSelectionUI, true);
  document.addEventListener('pointerdown', (event) => {
    if (feedButton && event.target !== feedButton && !feedButton.contains(event.target)) clearSelectionUI();
  }, true);
}());
