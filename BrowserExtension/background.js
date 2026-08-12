(function runPromptStudioBackground() {
  importScripts('background-logic.js', 'image-capture.js');
  const HOST_NAME = 'com.creatigo.promptstudio.capture';
  const logic = globalThis.PromptStudioBackgroundLogic;
  const image = globalThis.PromptStudioImageCapture;
  const ledger = new logic.PendingCaptureLedger();
  const imageSessions = new Map();
  const dragSessions = new Map();
  const pendingImageStarts = new Set();
  const IMAGE_MENU_ID = 'promptstudio-save-image';
  const PAGE_IMAGE_MENU_ID = 'promptstudio-recognize-page-image';
  let nativePort = null;
  let reconnectTimer = null;
  let reconnectAttempt = 0;

  function originForRuntime() {
    return `chrome-extension://${chrome.runtime.id}/`;
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;
    const delay = globalThis.PromptStudioSelection
      ? globalThis.PromptStudioSelection.nextReconnectDelay(reconnectAttempt)
      : Math.min(5_000, 100 * (2 ** reconnectAttempt));
    reconnectAttempt += 1;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connectNative();
    }, delay);
  }

  function sendToFrame(tabID, frameID, message) {
    if (!Number.isInteger(tabID) || !chrome.tabs || typeof chrome.tabs.sendMessage !== 'function') return;
    const callback = () => { void (chrome.runtime && chrome.runtime.lastError); };
    try {
      if (Number.isInteger(frameID)) chrome.tabs.sendMessage(tabID, message, { frameId: frameID }, callback);
      else chrome.tabs.sendMessage(tabID, message, callback);
    } catch {
      // A closed tab/frame is equivalent to a failed capture and cannot retain byte state.
    }
  }

  function sendToFrameAwait(tabID, frameID, message) {
    return new Promise((resolve) => {
      if (!Number.isInteger(tabID) || !chrome.tabs || typeof chrome.tabs.sendMessage !== 'function') {
        resolve(null);
        return;
      }
      let settled = false;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        resolve(value || null);
      };
      try {
        const callback = (response) => finish(response);
        if (Number.isInteger(frameID)) chrome.tabs.sendMessage(tabID, message, { frameId: frameID }, callback);
        else chrome.tabs.sendMessage(tabID, message, callback);
      } catch {
        finish(null);
      }
    });
  }

  function routeNativeResponse(response) {
    if (!response || !response.captureID) return;
    const captureID = response.captureID;
    const imageSession = imageSessions.get(captureID);
    if (imageSession) {
      imageSession.ledger.receive(response);
      sendToFrame(imageSession.tabID, imageSession.frameID, { type: 'imageCaptureResult', result: response });
      if (response.type === 'failed' || response.type === 'cancelled' || response.type === 'saved') {
        imageSessions.delete(captureID);
        if (imageSession.dragSession) dragSessions.delete(captureID);
      } else {
        pumpImageSession(imageSession);
      }
      return;
    }
    const dragSession = dragSessions.get(captureID);
    if (dragSession) {
      if (response.type === 'ack' || response.type === 'imageDragPreviewAck') {
        dragSession.previewPending = false;
        sendToFrame(dragSession.tabID, dragSession.frameID, { type: 'imageCaptureResult', result: response });
        pumpDragPreview(dragSession);
      } else {
        sendToFrame(dragSession.tabID, dragSession.frameID, { type: 'imageCaptureResult', result: response });
      }
      if (response.type === 'failed' || response.type === 'cancelled') dragSessions.delete(captureID);
      return;
    }
    const route = logic.captureRoute(ledger.entries, response);
    if (route) sendToFrame(route.tabID, route.frameID, { type: 'captureResult', result: response });
    ledger.receive(response);
  }

  function failDisconnectedImageSessions() {
    for (const session of imageSessions.values()) {
      sendToFrame(session.tabID, session.frameID, {
        type: 'imageCaptureResult',
        result: { type: 'failed', captureID: session.captureID, code: 'native-host-disconnected' },
      });
    }
    imageSessions.clear();
    for (const session of dragSessions.values()) {
      sendToFrame(session.tabID, session.frameID, {
        type: 'imageCaptureResult',
        result: { type: 'failed', captureID: session.captureID, code: 'native-host-disconnected' },
      });
    }
    dragSessions.clear();
  }

  function connectNative() {
    if (nativePort) return nativePort;
    try {
      nativePort = chrome.runtime.connectNative(HOST_NAME);
    } catch {
      nativePort = null;
      scheduleReconnect();
      return null;
    }
    nativePort.onMessage.addListener(routeNativeResponse);
    nativePort.onDisconnect.addListener(() => {
      nativePort = null;
      failDisconnectedImageSessions();
      scheduleReconnect();
    });
    reconnectAttempt = 0;
    replayPendingCaptures();
    return nativePort;
  }

  function replayPendingCaptures() {
    if (!nativePort) return;
    for (const entry of ledger.replayable()) {
      if (!ledger.markSent(entry.candidate.captureID)) continue;
      nativePort.postMessage({
        type: 'capture',
        origin: originForRuntime(),
        candidate: entry.candidate,
      });
    }
  }

  function sendCandidate(candidate, tabID, frameID) {
    const port = connectNative();
    ledger.add(candidate, tabID);
    const entry = ledger.entries.get(candidate.captureID);
    if (entry) entry.frameID = frameID;
    setTimeout(() => ledger.expire(Date.now()), logic.CAPTURE_TTL_MS + 1);
    if (!port || !ledger.markSent(candidate.captureID)) throw new Error('native-host-unavailable');
    port.postMessage({ type: 'capture', origin: originForRuntime(), candidate });
  }

  function pumpImageSession(session) {
    if (!nativePort || !imageSessions.has(session.captureID)) return;
    const next = session.ledger.next();
    if (!next) return;
    try {
      nativePort.postMessage(next.message);
    } catch {
      imageSessions.delete(session.captureID);
      sendToFrame(session.tabID, session.frameID, {
        type: 'imageCaptureResult',
        result: { type: 'failed', captureID: session.captureID, code: 'native-host-unavailable' },
      });
      scheduleReconnect();
    }
  }

  function startImageTransfer({ candidate, bytes, tabID, frameID, dragSession = null }) {
    if (!nativePort && !connectNative()) return Promise.reject(new Error('native-host-unavailable'));
    if (imageSessions.size) return Promise.reject(new Error('image-busy'));
    return (candidate.sha256 ? Promise.resolve(candidate.sha256) : image.sha256Hex(bytes)).then((sha256) => {
      const completeCandidate = image.makeImageCandidate({ ...candidate, byteCount: bytes.byteLength, sha256 });
      const messages = image.buildImageMessages({ origin: originForRuntime(), candidate: completeCandidate, bytes });
      const imageLedger = new image.ImageMessageLedger();
      imageLedger.begin({ captureID: completeCandidate.captureID, messages });
      const session = {
        captureID: completeCandidate.captureID,
        tabID,
        frameID,
        candidate: completeCandidate,
        ledger: imageLedger,
        dragSession,
      };
      imageSessions.set(session.captureID, session);
      pumpImageSession(session);
      return session;
    });
  }

  function executePageContextFetch(tabID, frameID, descriptor) {
    if (!descriptor || !descriptor.url || !chrome.scripting || typeof chrome.scripting.executeScript !== 'function') return Promise.resolve(null);
    return new Promise((resolve) => {
      try {
        chrome.scripting.executeScript({
          target: { tabId: tabID, frameIds: [frameID] },
          world: 'MAIN',
          args: [descriptor.url, descriptor.pageURL || ''],
          func: async (url, pageURL) => {
            try {
              const response = await fetch(url, { credentials: 'include', referrer: pageURL || undefined });
              if (!response.ok) return null;
              return await response.arrayBuffer();
            } catch {
              return null;
            }
          },
        }, (results) => resolve(results && results[0] ? results[0].result : null));
      } catch {
        resolve(null);
      }
    });
  }

  async function captureVisibleTabCrop(tab, frameID, descriptor) {
    if (!tab || typeof chrome.tabs.captureVisibleTab !== 'function') return null;
    const screenshot = await new Promise((resolve) => {
      try {
        chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' }, (dataURL) => resolve(dataURL || null));
      } catch {
        resolve(null);
      }
    });
    if (!screenshot) return null;
    const result = await sendToFrameAwait(tab.id, frameID, {
      type: 'cropImageScreenshot', dataURL: screenshot, crop: descriptor.crop,
    });
    return result && result.ok ? result.bytes : null;
  }

  async function acquireDescriptorBytes(tab, frameID, descriptor) {
    const acquired = await image.acquireImageBytes(descriptor, {
      pageContextFetch: () => executePageContextFetch(tab.id, frameID, descriptor),
      extensionFetch: async () => {
        if (!descriptor.url || /^(?:data|blob):/i.test(descriptor.url)) return null;
        try {
          const response = await fetch(descriptor.url, { credentials: 'include', referrer: descriptor.pageURL || undefined });
          return response.ok === false ? null : response;
        } catch {
          return null;
        }
      },
      loadedBytes: () => descriptor.loadedBytes || null,
      screenshot: () => captureVisibleTabCrop(tab, frameID, descriptor),
    });
    const sha256 = await image.sha256Hex(acquired.bytes);
    return {
      candidate: image.makeImageCandidate({ ...descriptor, acquisitionMethod: acquired.acquisitionMethod, isScreenshot: acquired.isScreenshot, mimeType: acquired.mimeType || descriptor.mimeType, byteCount: acquired.bytes.byteLength, sha256 }),
      bytes: acquired.bytes,
    };
  }

  async function captureFromContextMenu(info, tab, isImageContext) {
    if (!tab || !Number.isInteger(tab.id)) return;
    const frameID = Number.isInteger(info.frameId) ? info.frameId : 0;
    if (imageSessions.size || dragSessions.size || pendingImageStarts.size) {
      sendToFrame(tab.id, frameID, { type: 'imageCaptureResult', result: { type: 'failed', code: 'image-busy' } });
      return;
    }
    const captureID = globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function'
      ? globalThis.crypto.randomUUID() : `image-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    pendingImageStarts.add(captureID);
    const response = await sendToFrameAwait(tab.id, frameID, {
      type: 'resolveImageCapture',
      context: isImageContext ? 'image' : 'page',
      srcUrl: isImageContext ? (info.srcUrl || '') : '',
      x: Number.isFinite(info.x) ? info.x : null,
      y: Number.isFinite(info.y) ? info.y : null,
      pageURL: info.pageUrl || tab.url || '',
      captureID,
    });
    if (!response || !response.ok || !response.descriptor) {
      pendingImageStarts.delete(captureID);
      sendToFrame(tab.id, frameID, { type: 'imageCaptureResult', result: { type: 'failed', captureID, code: 'image-not-found' } });
      return;
    }
    try {
      const acquired = await acquireDescriptorBytes(tab, frameID, { ...response.descriptor, captureID });
      await startImageTransfer({ ...acquired, tabID: tab.id, frameID });
    } catch (error) {
      sendToFrame(tab.id, frameID, { type: 'imageCaptureResult', result: { type: 'failed', captureID, code: error && error.message === 'image exceeds 50 MiB' ? 'image-too-large' : 'image-acquisition-failed' } });
    } finally {
      pendingImageStarts.delete(captureID);
    }
  }

  function postDragPreview(session) {
    if (!nativePort || session.previewPending || !session.latestPoint) return;
    session.previewPending = true;
    try {
      nativePort.postMessage({ type: 'imageDragPreview', origin: originForRuntime(), captureID: session.captureID, screenPoint: session.latestPoint, insidePet: session.insidePet, drop: false });
    } catch {
      session.previewPending = false;
      sendToFrame(session.tabID, session.frameID, { type: 'imageCaptureResult', result: { type: 'failed', captureID: session.captureID, code: 'native-host-unavailable' } });
      scheduleReconnect();
    }
  }

  function pumpDragPreview(session) {
    if (session.latestPoint && !session.previewPending) postDragPreview(session);
  }

  async function startDrag(tabID, frameID, descriptor) {
    if (!Number.isInteger(tabID) || imageSessions.size || dragSessions.size || pendingImageStarts.size) throw new Error('image-busy');
    const session = { captureID: descriptor.captureID, tabID, frameID, descriptor, bytesPromise: null, latestPoint: null, insidePet: false, previewPending: false };
    dragSessions.set(session.captureID, session);
    const tabPromise = chrome.tabs && typeof chrome.tabs.get === 'function'
      ? new Promise((resolve) => {
        try { chrome.tabs.get(tabID, (tab) => resolve(tab || { id: tabID })); } catch { resolve({ id: tabID }); }
      })
      : Promise.resolve({ id: tabID });
    session.bytesPromise = tabPromise.then((tab) => acquireDescriptorBytes(tab, frameID, descriptor))
      .catch((error) => { session.prefetchError = error; return null; });
    if (!nativePort && !connectNative()) {
      dragSessions.delete(session.captureID);
      throw new Error('native-host-unavailable');
    }
    return session;
  }

  async function dropDrag(captureID) {
    const session = dragSessions.get(captureID);
    if (!session) throw new Error('image-session-not-found');
    const acquired = await session.bytesPromise;
    if (!acquired) {
      dragSessions.delete(captureID);
      throw session.prefetchError || new Error('image-acquisition-failed');
    }
    dragSessions.delete(captureID);
    return startImageTransfer({ ...acquired, tabID: session.tabID, frameID: session.frameID, dragSession: session });
  }

  function cancelDrag(captureID) {
    const session = dragSessions.get(captureID);
    if (!session) return;
    dragSessions.delete(captureID);
    if (nativePort) {
      try { nativePort.postMessage({ type: 'imageDragCancel', origin: originForRuntime(), captureID }); } catch { /* disconnect cleanup handles it */ }
    }
  }

  function createContextMenus() {
    if (!chrome.contextMenus || typeof chrome.contextMenus.create !== 'function') return;
    const create = () => {
      chrome.contextMenus.create({ id: IMAGE_MENU_ID, title: '收藏图片到 PromptStudio', contexts: ['image'] });
      chrome.contextMenus.create({ id: PAGE_IMAGE_MENU_ID, title: '识别此处图片并收藏', contexts: ['page'] });
    };
    if (typeof chrome.contextMenus.removeAll === 'function') chrome.contextMenus.removeAll(create);
    else create();
  }

  if (chrome.runtime && chrome.runtime.onInstalled) chrome.runtime.onInstalled.addListener(createContextMenus);
  if (chrome.contextMenus && chrome.contextMenus.onClicked) {
    chrome.contextMenus.onClicked.addListener((info, tab) => {
      if (info && tab && info.menuItemId === IMAGE_MENU_ID) captureFromContextMenu(info, tab, true);
      else if (info && tab && info.menuItemId === PAGE_IMAGE_MENU_ID) captureFromContextMenu(info, tab, false);
    });
  }

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message && message.type === 'startImageDrag') {
      startDrag(sender.tab && sender.tab.id, sender.frameId, message.descriptor || {})
        .then((session) => sendResponse({ ok: true, captureID: session.captureID }))
        .catch((error) => sendResponse({ ok: false, code: error.message === 'image-busy' ? 'image-busy' : 'image-acquisition-failed' }));
      return true;
    }
    if (message && message.type === 'previewImageDrag') {
      const session = dragSessions.get(message.captureID);
      if (!session) { sendResponse({ ok: false, code: 'image-session-not-found' }); return false; }
      session.latestPoint = message.screenPoint || message.point || null;
      session.insidePet = Boolean(message.insidePet);
      pumpDragPreview(session);
      sendResponse({ ok: true });
      return false;
    }
    if (message && message.type === 'dropImageDrag') {
      dropDrag(message.captureID)
        .then(() => sendResponse({ ok: true }))
        .catch((error) => sendResponse({ ok: false, code: error.message || 'image-acquisition-failed' }));
      return true;
    }
    if (message && message.type === 'cancelImageDrag') {
      cancelDrag(message.captureID);
      sendResponse({ ok: true });
      return false;
    }
    if (!message || message.type !== 'captureCandidate' || !message.candidate) return false;
    const tabID = sender.tab && sender.tab.id;
    if (!Number.isInteger(tabID)) {
      sendResponse({ ok: false, code: 'missing-tab' });
      return false;
    }
    try {
      sendCandidate(message.candidate, tabID, sender.frameId);
      sendResponse({ ok: true });
    } catch {
      sendResponse({ ok: false, code: 'native-host-unavailable' });
      scheduleReconnect();
    }
    return false;
  });

  createContextMenus();
  connectNative();
}());
