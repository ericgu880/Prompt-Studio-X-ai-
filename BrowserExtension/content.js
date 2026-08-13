(function runPromptStudioContent() {
  const S = globalThis.PromptStudioSelection;
  const C = globalThis.PromptStudioContentCore;
  const I = globalThis.PromptStudioImageCapture;
  if (!S || !C || !I || !document.body) return;

  const restrictedPage = !['http:', 'https:'].includes(location.protocol);
  let feedButton = null;
  let notice = null;
  let selectionTimer = null;
  let removeTimer = null;
  let selectionRange = null;
  let selectionRect = null;
  const captureOrigins = new Map();
  const animatedCaptureIDs = new Set();
  const localByteStore = new I.FrameByteStore({ ttlMs: 300_000 });
  const screenshotAssemblies = new Map();
  let dragSession = null;
  let preparedImageDrag = null;
  let mouthDuplicate = null;
  let lastPointerPoint = { x: 0, y: 0, screenX: null, screenY: null };

  function sendRuntimeMessage(message, callback) {
    let runtime = null;
    try {
      runtime = globalThis.chrome && globalThis.chrome.runtime;
    } catch {
      runtime = null;
    }
    if (!runtime || typeof runtime.sendMessage !== 'function') {
      if (typeof callback === 'function') callback(null, { message: 'extension-context-invalidated' });
      return false;
    }
    try {
      runtime.sendMessage(message, (response) => {
        let lastError = null;
        try {
          lastError = runtime.lastError || null;
        } catch {
          lastError = { message: 'extension-context-invalidated' };
        }
        if (typeof callback === 'function') callback(response, lastError);
      });
      return true;
    } catch (error) {
      if (typeof callback === 'function') callback(null, error);
      return false;
    }
  }

  function elementAtPoint(x, y, srcUrl) {
    let element = Number.isFinite(x) && Number.isFinite(y) && document.elementFromPoint(x, y);
    if (element && element.nodeType === Node.TEXT_NODE) element = element.parentElement;
    const imageElement = element && element.closest && element.closest('img, picture, canvas, svg');
    if (imageElement) return imageElement;
    if (srcUrl && document.images) {
      return Array.from(document.images).find((candidate) => candidate.currentSrc === srcUrl || candidate.src === srcUrl) || null;
    }
    return element || null;
  }

  function clearPreparedImageDrag() {
    if (!preparedImageDrag) return;
    const prepared = preparedImageDrag;
    preparedImageDrag = null;
    if (!prepared.dragRoot) return;
    if (prepared.hadDraggableAttribute) {
      prepared.dragRoot.setAttribute('draggable', prepared.draggableAttribute);
    } else {
      prepared.dragRoot.removeAttribute('draggable');
    }
    if (prepared.dragRoot.style) prepared.dragRoot.style.webkitUserDrag = prepared.webkitUserDrag;
  }

  function prepareImageDrag(event) {
    if (!event || event.button !== 0 || dragSession) return;
    clearPreparedImageDrag();
    const layers = typeof document.elementsFromPoint === 'function'
      ? document.elementsFromPoint(event.clientX, event.clientY) : [];
    const hit = I.resolveImageDragHit(event.target, layers, { x: event.clientX, y: event.clientY });
    if (!hit || !hit.imageElement || !hit.dragRoot) return;
    const root = hit.dragRoot;
    const elementRect = typeof hit.imageElement.getBoundingClientRect === 'function'
      ? hit.imageElement.getBoundingClientRect() : null;
    const sourceScreenRect = elementRect ? I.screenRectFromPointerRect(elementRect, {
      clientX: event.clientX,
      clientY: event.clientY,
      screenX: event.screenX,
      screenY: event.screenY,
    }) : null;
    preparedImageDrag = {
      imageElement: hit.imageElement,
      dragRoot: root,
      sourceScreenRect,
      hadDraggableAttribute: root.hasAttribute('draggable'),
      draggableAttribute: root.getAttribute('draggable'),
      webkitUserDrag: root.style ? root.style.webkitUserDrag : '',
    };
    root.setAttribute('draggable', 'true');
    if (root.style) root.style.webkitUserDrag = 'element';
  }

  async function descriptorForCapture(request) {
    const x = Number.isFinite(request.x) ? request.x : lastPointerPoint.x;
    const y = Number.isFinite(request.y) ? request.y : lastPointerPoint.y;
    const element = request.element || elementAtPoint(x, y, request.srcUrl);
    let descriptor = I.resolveImageDescriptor(element, {
      viewportWidth: window.innerWidth,
      devicePixelRatio: window.devicePixelRatio,
      allowCSSBackground: request.context === 'page',
      baseURL: location.href,
    });
    if (!descriptor && request.srcUrl) descriptor = I.classifyImageSource(request.srcUrl);
    if (!descriptor) return null;
    const rect = element && typeof element.getBoundingClientRect === 'function'
      ? element.getBoundingClientRect() : null;
    const clickScreenPoint = {
      x: Number.isFinite(request.screenX) ? request.screenX
        : (Number.isFinite(lastPointerPoint.screenX) ? lastPointerPoint.screenX : window.screenX + x),
      y: Number.isFinite(request.screenY) ? request.screenY
        : (Number.isFinite(lastPointerPoint.screenY) ? lastPointerPoint.screenY : window.screenY + y),
    };
    const screenRect = rect ? I.screenRectFromPointerRect(rect, {
      clientX: x,
      clientY: y,
      screenX: clickScreenPoint.x,
      screenY: clickScreenPoint.y,
    }) : null;
    return {
      captureID: request.captureID,
      sourcePoint: { x, y },
      pageTitle: document.title || '',
      pageURL: location.href,
      siteName: S.siteNameFromURL(location.href),
      resourceURL: descriptor.url || null,
      url: descriptor.url || null,
      altText: element && typeof element.alt === 'string' ? element.alt : '',
      originalFileName: descriptor.url ? (descriptor.url.split('/').pop() || '').split('?')[0] : '',
      domSourceKind: descriptor.domSourceKind,
      acquisitionMethod: 'pageContext',
      isScreenshot: false,
      mimeType: descriptor.domSourceKind === 'inlineSVG' ? 'image/svg+xml' : null,
      pixelWidth: element && Number.isFinite(element.naturalWidth) && element.naturalWidth ? element.naturalWidth : null,
      pixelHeight: element && Number.isFinite(element.naturalHeight) && element.naturalHeight ? element.naturalHeight : null,
      clickScreenPoint,
      capturedAt: new Date().toISOString(),
      screenRect,
      devicePixelRatio: window.devicePixelRatio,
      crop: null,
    };
  }

  async function cropScreenshot(dataURL, crop, screenRect = null, topMetrics = null, devicePixelRatio = 1) {
    if (!dataURL || !crop || !crop.width || !crop.height) return null;
    return new Promise((resolve) => {
      const imageElement = new Image();
      imageElement.onload = async () => {
        const effectiveCrop = screenRect
          ? I.cropRectFromScreenRect(screenRect, topMetrics || {}, devicePixelRatio,
            { width: imageElement.naturalWidth || imageElement.width, height: imageElement.naturalHeight || imageElement.height })
          : crop;
        const left = Math.max(0, Math.min(imageElement.naturalWidth || imageElement.width, Number(effectiveCrop.left) || 0));
        const top = Math.max(0, Math.min(imageElement.naturalHeight || imageElement.height, Number(effectiveCrop.top) || 0));
        const right = Math.max(left, Math.min(imageElement.naturalWidth || imageElement.width, (Number(effectiveCrop.left) || 0) + (Number(effectiveCrop.width) || 0)));
        const bottom = Math.max(top, Math.min(imageElement.naturalHeight || imageElement.height, (Number(effectiveCrop.top) || 0) + (Number(effectiveCrop.height) || 0)));
        if (right <= left || bottom <= top) { resolve(null); return; }
        const canvas = document.createElement('canvas');
        canvas.width = right - left;
        canvas.height = bottom - top;
        const context = canvas.getContext('2d');
        if (!context) { resolve(null); return; }
        context.drawImage(imageElement, left, top, right - left, bottom - top, 0, 0, right - left, bottom - top);
        try {
          canvas.toBlob(async (blob) => resolve(blob ? await I.responseBytes(blob) : null), 'image/png');
        } catch { resolve(null); }
      };
      imageElement.onerror = () => resolve(null);
      imageElement.src = dataURL;
    });
  }

  function clearMouthDuplicate() {
    if (mouthDuplicate) mouthDuplicate.remove();
    mouthDuplicate = null;
  }

  function renderMouthDuplicate(result) {
    clearMouthDuplicate();
    if (!dragSession || !result || !result.insidePet || !dragSession.element) return;
    const duplicate = dragSession.element.cloneNode(true);
    duplicate.classList.add('promptstudio-capture-mouth-duplicate');
    duplicate.removeAttribute('id');
    duplicate.setAttribute('aria-hidden', 'true');
    duplicate.width = 36;
    duplicate.height = 36;
    const point = result.mouthScreenPoint || result.mouthPoint;
    const viewportPoint = point ? S.mapScreenPointToViewport(point, {
      screenX: window.screenX, screenY: window.screenY, outerHeight: window.outerHeight, innerHeight: window.innerHeight,
      visualViewportOffsetX: globalThis.visualViewport ? visualViewport.offsetLeft : 0,
      visualViewportOffsetY: globalThis.visualViewport ? visualViewport.offsetTop : 0,
      devicePixelRatio: window.devicePixelRatio, screenCoordinatesArePhysicalPixels: false,
    }) : { x: 0, y: 0 };
    duplicate.style.left = `${Math.max(0, viewportPoint.x - 18)}px`;
    duplicate.style.top = `${Math.max(0, viewportPoint.y - 18)}px`;
    duplicate.style.width = '36px';
    duplicate.style.height = '36px';
    document.documentElement.appendChild(duplicate);
    mouthDuplicate = duplicate;
  }

  function clearDragSession() {
    clearMouthDuplicate();
    dragSession = null;
    clearPreparedImageDrag();
  }

  function sendDragPreview(event) {
    if (!dragSession || !dragSession.captureID) return;
    dragSession.previewSequence = (dragSession.previewSequence || 0) + 1;
    dragSession.lastScreenPoint = { x: event.screenX, y: event.screenY };
    sendRuntimeMessage(I.makeDragPreviewMessage({
      captureID: dragSession.captureID,
      screenPoint: { x: event.screenX, y: event.screenY },
      sourceScreenRect: dragSession.sourceScreenRect,
      sequence: dragSession.previewSequence,
    }));
  }

  function beginImageDrag(event) {
    const layers = typeof document.elementsFromPoint === 'function'
      ? document.elementsFromPoint(event.clientX, event.clientY) : [];
    const hit = I.resolveImageDragHit(event.target, layers, { x: event.clientX, y: event.clientY });
    const element = preparedImageDrag && preparedImageDrag.imageElement
      ? preparedImageDrag.imageElement : hit && hit.imageElement;
    if (!element || dragSession) return;
    if (preparedImageDrag && preparedImageDrag.dragRoot !== element
        && typeof event.stopImmediatePropagation === 'function') {
      event.stopImmediatePropagation();
    }
    if (event.dataTransfer && typeof event.dataTransfer.setDragImage === 'function') {
      const rect = typeof element.getBoundingClientRect === 'function' ? element.getBoundingClientRect() : null;
      event.dataTransfer.setDragImage(element, rect ? Math.max(0, event.clientX - rect.left) : 0,
        rect ? Math.max(0, event.clientY - rect.top) : 0);
    }
    const elementRect = typeof element.getBoundingClientRect === 'function'
      ? element.getBoundingClientRect() : null;
    const dragStartScreenRect = elementRect ? I.screenRectFromPointerRect(elementRect, {
      clientX: event.clientX,
      clientY: event.clientY,
      screenX: event.screenX,
      screenY: event.screenY,
    }) : null;
    const sourceScreenRect = I.preferredDragSourceScreenRect(
      preparedImageDrag && preparedImageDrag.sourceScreenRect,
      dragStartScreenRect,
    );
    const captureID = globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function'
      ? globalThis.crypto.randomUUID() : `image-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    dragSession = {
      captureID,
      element,
      dropped: false,
      started: true,
      // Sequence 1 is sent immediately, before descriptor/byte prefetch.
      // That lets the desktop pet appear beside the source image right away.
      previewSequence: 1,
      nativeInsidePet: false,
      nativeMouthScreenPoint: null,
      nativeSequence: 0,
      lastScreenPoint: { x: event.screenX, y: event.screenY },
      finalSequence: null,
      finalPending: false,
      finalTimer: null,
      sourceScreenRect,
    };
    sendRuntimeMessage({
      type: 'beginImageDragPreview',
      captureID,
      screenPoint: dragSession.lastScreenPoint,
      sourceScreenRect,
      sequence: dragSession.previewSequence,
    }, (_response, lastError) => {
      if (lastError) clearDragSession();
    });
    descriptorForCapture({ captureID, context: 'image', element, x: event.clientX, y: event.clientY, screenX: event.screenX, screenY: event.screenY, srcUrl: element.currentSrc || element.src || '' })
      .then((descriptor) => {
        if (!dragSession || dragSession.captureID !== captureID || !descriptor) return;
        dragSession.descriptor = descriptor;
        sendRuntimeMessage({ type: 'startImageDrag', descriptor }, (response, lastError) => {
          if (lastError || !response || !response.ok) {
            sendRuntimeMessage({ type: 'cancelImageDrag', captureID });
            clearDragSession();
            showNotice(response && response.code === 'image-busy' ? 'PromptStudio 正在处理另一张图片。' : '图片预取失败，请重试。', { left: event.clientX, top: event.clientY });
          } else {
            sendDragPreview(event);
          }
        });
      })
      .catch(() => {
        sendRuntimeMessage({ type: 'cancelImageDrag', captureID });
        clearDragSession();
      });
  }

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
    sendRuntimeMessage({ type: 'captureCandidate', candidate }, (response, lastError) => {
      if (lastError || !response || !response.ok) {
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

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message && message.type === 'getTopViewportMetrics') {
      let isTop = true;
      try { isTop = window.top === window; } catch { isTop = false; }
      if (!isTop) { sendResponse({ ok: false, code: 'not-top-frame' }); return false; }
      sendResponse({
        ok: true,
        screenX: Number(window.screenX) || 0,
        screenY: Number(window.screenY) || 0,
        browserChromeHeight: Math.max(0, Number(window.outerHeight || 0) - Number(window.innerHeight || 0)),
        viewportWidth: Number(window.innerWidth) || 0,
        viewportHeight: Number(window.innerHeight) || 0,
        devicePixelRatio: Number(window.devicePixelRatio) || 1,
      });
      return false;
    }
    if (message && message.type === 'resolveImageCapture') {
      descriptorForCapture(message).then((descriptor) => {
        sendResponse(descriptor ? { ok: true, descriptor } : { ok: false, code: 'image-not-found' });
      }).catch(() => sendResponse({ ok: false, code: 'image-not-found' }));
      return true;
    }
    if (message && message.type === 'cropImageScreenshotStart') {
      screenshotAssemblies.set(message.captureID, {
        chunks: [], total: Number(message.totalChunks) || 0, crop: message.crop,
        screenRect: message.screenRect, topMetrics: message.topMetrics, devicePixelRatio: message.devicePixelRatio,
      });
      sendResponse({ ok: true });
      return false;
    }
    if (message && message.type === 'cropImageScreenshotChunk') {
      const assembly = screenshotAssemblies.get(message.captureID);
      if (!assembly || !Number.isInteger(message.index) || message.index < 0) { sendResponse({ ok: false }); return false; }
      assembly.chunks[message.index] = String(message.data || '');
      sendResponse({ ok: true });
      return false;
    }
    if (message && message.type === 'cropImageScreenshotEnd') {
      const assembly = screenshotAssemblies.get(message.captureID);
      if (!assembly || assembly.chunks.length < assembly.total
          || assembly.chunks.some((chunk) => typeof chunk !== 'string')) {
        sendResponse({ ok: false, code: 'screenshot-crop-failed' });
        return false;
      }
      screenshotAssemblies.delete(message.captureID);
      cropScreenshot(assembly.chunks.join(''), assembly.crop, assembly.screenRect, assembly.topMetrics, assembly.devicePixelRatio).then((bytes) => {
        if (!bytes) { sendResponse({ ok: false, code: 'screenshot-crop-failed' }); return; }
        const stored = localByteStore.start(bytes, { mimeType: 'image/png' });
        sendResponse({ ok: true, storeID: stored.storeID, byteCount: stored.byteCount, mimeType: stored.mimeType });
      }).catch(() => sendResponse({ ok: false, code: 'screenshot-crop-failed' }));
      return true;
    }
    if (message && message.type === 'readImageByteChunk') {
      sendResponse(localByteStore.read(message.storeID, message.index) || { ok: false });
      return false;
    }
    if (message && message.type === 'releaseImageByteStore') {
      sendResponse({ ok: localByteStore.release(message.storeID) });
      return false;
    }
    if (message && message.type === 'imageCaptureResult') {
      const result = message.result || {};
      if (dragSession && result.captureID === dragSession.captureID) {
        const isPreviewAck = result.type === 'imageDragPreviewAck'
          || (result.type === 'ack' && (Number.isInteger(Number(result.sequence))
            || /drag[-_]?preview/i.test(String(result.code || ''))));
        if (isPreviewAck) {
          const sequence = Number(result.sequence);
          if (!Number.isInteger(sequence)) return false;
          if (dragSession.finalPending) {
            if (sequence !== dragSession.finalSequence) return false;
            dragSession.finalPending = false;
            if (dragSession.finalTimer) clearTimeout(dragSession.finalTimer);
            dragSession.finalTimer = null;
            dragSession.nativeInsidePet = Boolean(result.insidePet);
            dragSession.nativeMouthScreenPoint = result.mouthScreenPoint || result.mouthPoint || null;
            renderMouthDuplicate({
              insidePet: dragSession.nativeInsidePet,
              mouthScreenPoint: dragSession.nativeMouthScreenPoint,
            });
            if (dragSession.nativeInsidePet) {
              dragSession.dropped = true;
              sendRuntimeMessage({ type: 'dropImageDrag', captureID: dragSession.captureID }, (response, lastError) => {
                if (lastError || !response || !response.ok) clearDragSession();
              });
            } else {
              sendRuntimeMessage({ type: 'cancelImageDrag', captureID: dragSession.captureID });
              clearDragSession();
            }
            return false;
          }
          if (sequence <= (dragSession.nativeSequence || 0)) return false;
          dragSession.nativeSequence = sequence;
          // Only native feedback controls the mouth duplicate.  Page-local hit testing is
          // intentionally not used because a native window may be outside this tab.
          dragSession.nativeInsidePet = Boolean(result.insidePet);
          dragSession.nativeMouthScreenPoint = result.mouthScreenPoint || result.mouthPoint || null;
          renderMouthDuplicate({
            insidePet: dragSession.nativeInsidePet,
            mouthScreenPoint: dragSession.nativeMouthScreenPoint,
          });
        } else if (result.type === 'failed') {
          showNotice(result.code === 'image-busy' ? 'PromptStudio 正在处理另一张图片。' : '图片采集失败，请重试。', { left: 12, top: 12 });
          clearDragSession();
        } else if (result.type === 'saved' || result.type === 'cancelled') {
          clearDragSession();
        }
      }
      return false;
    }
    if (!message || message.type !== 'captureResult') return false;
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
    if (result.type === 'saved' && result.clearSource) {
      const selection = window.getSelection();
      if (selection && typeof selection.removeAllRanges === 'function') selection.removeAllRanges();
    }
  });

  document.addEventListener('selectionchange', scheduleSelection, true);
  document.addEventListener('pointerdown', prepareImageDrag, true);
  document.addEventListener('pointerup', () => {
    if (!dragSession) clearPreparedImageDrag();
  }, true);
  document.addEventListener('pointercancel', () => {
    if (!dragSession) clearPreparedImageDrag();
  }, true);
  document.addEventListener('pointermove', (event) => {
    lastPointerPoint = { x: event.clientX, y: event.clientY, screenX: event.screenX, screenY: event.screenY };
  }, true);
  document.addEventListener('contextmenu', (event) => {
    lastPointerPoint = { x: event.clientX, y: event.clientY, screenX: event.screenX, screenY: event.screenY };
  }, true);
  document.addEventListener('dragstart', beginImageDrag, true);
  document.addEventListener('dragover', (event) => {
    if (!dragSession) return;
    event.preventDefault();
    sendDragPreview(event);
  }, true);
  document.addEventListener('drop', (event) => {
    if (!dragSession) return;
    event.preventDefault();
    dragSession.pageDropped = true;
    dragSession.lastScreenPoint = { x: event.screenX, y: event.screenY };
  }, true);
  document.addEventListener('dragend', (event) => {
    if (!dragSession) return;
    if (dragSession.dropped) return;
    if (dragSession.finalPending) return;
    dragSession.previewSequence = Math.max(dragSession.previewSequence || 0, dragSession.nativeSequence || 0) + 1;
    dragSession.finalSequence = dragSession.previewSequence;
    dragSession.finalPending = true;
    const finalSequence = dragSession.finalSequence;
    const point = I.dragEndScreenPoint(
      event,
      dragSession.lastScreenPoint || { x: window.screenX, y: window.screenY },
    );
    dragSession.lastScreenPoint = point;
    dragSession.finalTimer = setTimeout(() => {
      if (!dragSession || !dragSession.finalPending || dragSession.finalSequence !== finalSequence) return;
      sendRuntimeMessage({ type: 'cancelImageDrag', captureID: dragSession.captureID });
      clearDragSession();
    }, I.FINAL_HIT_TIMEOUT_MS);
    sendRuntimeMessage({ type: 'finalizeImageDrag', captureID: dragSession.captureID, sequence: finalSequence, screenPoint: point }, (response, lastError) => {
      if (lastError || !response || !response.ok) {
        if (dragSession && dragSession.finalSequence === finalSequence) {
          clearTimeout(dragSession.finalTimer);
          sendRuntimeMessage({ type: 'cancelImageDrag', captureID: dragSession.captureID });
          clearDragSession();
        }
      }
    });
  }, true);
  window.addEventListener('scroll', clearSelectionUI, true);
  window.addEventListener('resize', clearSelectionUI, true);
  document.addEventListener('pointerdown', (event) => {
    if (feedButton && event.target !== feedButton && !feedButton.contains(event.target)) clearSelectionUI();
  }, true);
}());
