(function runPromptStudioBackground() {
  importScripts('background-logic.js', 'image-capture.js');
  const HOST_NAME = 'com.creatigo.promptstudio.capture';
  const logic = globalThis.PromptStudioBackgroundLogic;
  const image = globalThis.PromptStudioImageCapture;
  const ledger = new logic.PendingCaptureLedger();
  const imageSessions = new Map();
  const dragSessions = new Map();
  const pendingImageStarts = new Set();
  const MAX_STORE_TTL_MS = 300_000;
  const MAX_REPLAY_ATTEMPTS = 3;
  const FINAL_HIT_TIMEOUT_MS = 800;
  // Task4/Host contract: response fields are forwarded unchanged when present.
  const IMAGE_DRAG_WIRE_FIELDS = ['sequence', 'insidePet', 'mouthScreenPoint'];
  const IMAGE_MENU_ID = 'promptstudio-save-image';
  const PAGE_IMAGE_MENU_ID = 'promptstudio-recognize-page-image';
  let nativePort = null;
  let reconnectTimer = null;
  let reconnectAttempt = 0;

  function originForRuntime() {
    return `chrome-extension://${chrome.runtime.id}/`;
  }

  function scheduleReconnect() {
    // Native Messaging reports a visible extension error for every failed
    // connection attempt. Reconnect only while an actual capture is in flight;
    // idle extensions must not keep probing the host in the background.
    if (!imageSessions.size && !dragSessions.size && !ledger.entries.size) return;
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

  function executeScriptAwait(details) {
    return new Promise((resolve) => {
      if (!chrome.scripting || typeof chrome.scripting.executeScript !== 'function') { resolve(null); return; }
      try {
        chrome.scripting.executeScript(details, (results) => resolve(results && results[0] ? results[0].result : null));
      } catch {
        resolve(null);
      }
    });
  }

  async function readFrameStore(tabID, frameID, info) {
    if (!info || !info.storeID || !Number.isFinite(Number(info.byteCount))) return null;
    const byteCount = Number(info.byteCount);
    if (byteCount < 0 || byteCount > image.MAX_IMAGE_BYTES) return null;
    const chunkCount = Math.ceil(byteCount / image.IMAGE_CHUNK_BYTES);
    const bytes = new Uint8Array(byteCount);
    let offset = 0;
    try {
      for (let index = 0; index < chunkCount; index += 1) {
        const response = await executeScriptAwait({
          target: { tabId: tabID, frameIds: [frameID] },
          world: 'MAIN',
          args: [info.storeID, index],
          func: (storeID, chunkIndex) => {
            const stores = globalThis.__PROMPTSTUDIO_IMAGE_BYTE_STORES__;
            const store = stores && stores.get(storeID);
            if (!store || chunkIndex < 0) return null;
            const start = chunkIndex * 512 * 1024;
            if (start >= store.bytes.byteLength) return null;
            const chunk = new Uint8Array(store.bytes.slice(start, Math.min(store.bytes.byteLength, start + 512 * 1024)));
            let binary = '';
            for (let cursor = 0; cursor < chunk.length; cursor += 0x8000) binary += String.fromCharCode(...chunk.subarray(cursor, cursor + 0x8000));
            const base64Data = btoa(binary);
            if (base64Data.length >= 1024 * 1024) return null;
            return { storeID, index: chunkIndex, base64Data, byteCount: chunk.byteLength, mimeType: store.mimeType };
          },
        });
        if (!response || response.storeID !== info.storeID || response.index !== index || typeof response.base64Data !== 'string') return null;
        const chunk = image.decodeBase64(response.base64Data);
        if (chunk.byteLength > image.IMAGE_CHUNK_BYTES || offset + chunk.byteLength > byteCount) return null;
        bytes.set(chunk, offset);
        offset += chunk.byteLength;
      }
      return offset === byteCount ? { bytes, mimeType: info.mimeType || null } : null;
    } finally {
      await executeScriptAwait({
        target: { tabId: tabID, frameIds: [frameID] },
        world: 'MAIN',
        args: [info.storeID],
        func: (storeID) => {
          const stores = globalThis.__PROMPTSTUDIO_IMAGE_BYTE_STORES__;
          return Boolean(stores && stores.delete(storeID));
        },
      });
    }
  }

  async function readContentStore(tabID, frameID, info) {
    if (!info || !info.storeID || !Number.isFinite(Number(info.byteCount))) return null;
    const byteCount = Number(info.byteCount);
    if (byteCount < 0 || byteCount > image.MAX_IMAGE_BYTES) return null;
    const bytes = new Uint8Array(byteCount);
    let offset = 0;
    try {
      for (let index = 0; index < Math.ceil(byteCount / image.IMAGE_CHUNK_BYTES); index += 1) {
        const response = await sendToFrameAwait(tabID, frameID, { type: 'readImageByteChunk', storeID: info.storeID, index });
        if (!response || response.storeID !== info.storeID || response.index !== index || typeof response.base64Data !== 'string') return null;
        const chunk = image.decodeBase64(response.base64Data);
        if (chunk.byteLength > image.IMAGE_CHUNK_BYTES || offset + chunk.byteLength > byteCount) return null;
        bytes.set(chunk, offset);
        offset += chunk.byteLength;
      }
      return offset === byteCount ? { bytes, mimeType: info.mimeType || null } : null;
    } finally {
      await sendToFrameAwait(tabID, frameID, { type: 'releaseImageByteStore', storeID: info.storeID });
    }
  }

  function routeNativeResponse(response) {
    if (!response || !response.captureID) return;
    const captureID = response.captureID;
    const imageSession = imageSessions.get(captureID);
    if (imageSession) {
      const accepted = imageSession.ledger.receive(response);
      sendToFrame(imageSession.tabID, imageSession.frameID, { type: 'imageCaptureResult', result: response });
      if (accepted && (response.type === 'failed' || response.type === 'cancelled' || response.type === 'saved')) {
        imageSessions.delete(captureID);
        imageSession.bytes = null;
        imageSession.messages = [];
        if (imageSession.dragSession) dragSessions.delete(captureID);
      } else {
        pumpImageSession(imageSession);
      }
      return;
    }
    const dragSession = dragSessions.get(captureID);
    if (dragSession) {
      if (response.type === 'ack' || response.type === 'imageDragPreviewAck') {
        const sequence = Number(response.sequence);
        const pending = Number.isInteger(sequence) ? dragSession.pendingPreviews.get(sequence) : null;
        if (!pending) return;
        dragSession.pendingPreviews.delete(sequence);
        dragSession.previewPending = false;
        if (pending.final && sequence === dragSession.finalSequence) dragSession.finalPending = false;
        const previewResponse = { ...response, sequence };
        sendToFrame(dragSession.tabID, dragSession.frameID, { type: 'imageCaptureResult', result: previewResponse });
        if (!pending.final) pumpDragPreview(dragSession);
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

  function failImageSession(session, code = 'native-host-disconnected') {
    if (!session || !imageSessions.has(session.captureID)) return;
    imageSessions.delete(session.captureID);
    session.bytes = null;
    session.messages = [];
    session.ledger.cancel();
    sendToFrame(session.tabID, session.frameID, {
      type: 'imageCaptureResult',
      result: { type: 'failed', captureID: session.captureID, code },
    });
    if (session.dragSession) dragSessions.delete(session.captureID);
  }

  function replayImageSessions() {
    const now = Date.now();
    for (const session of imageSessions.values()) {
      if (now - session.createdAt >= MAX_STORE_TTL_MS) {
        failImageSession(session, 'image-transfer-expired');
        continue;
      }
      if (!session.awaitingReplay) continue;
      if (session.replayAttempts >= MAX_REPLAY_ATTEMPTS) {
        failImageSession(session, 'native-host-disconnected');
        continue;
      }
      session.replayAttempts += 1;
      session.awaitingReplay = false;
      session.ledger.replay();
      pumpImageSession(session);
    }
  }

  function failDisconnectedImageSessions() {
    for (const session of imageSessions.values()) {
      if (Date.now() - session.createdAt >= MAX_STORE_TTL_MS || session.replayAttempts >= MAX_REPLAY_ATTEMPTS) {
        failImageSession(session);
      } else {
        session.awaitingReplay = true;
      }
    }
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
    const connectedPort = nativePort;
    connectedPort.onMessage.addListener(routeNativeResponse);
    connectedPort.onDisconnect.addListener(() => {
      // Reading lastError inside the callback marks the native disconnect as
      // handled. Without this, Chrome records an extension error every time a
      // service worker reload closes its native host.
      void chrome.runtime.lastError;
      // A delayed callback from an older port must not tear down a newer
      // connection that has already replaced it.
      if (nativePort !== connectedPort) return;
      nativePort = null;
      failDisconnectedImageSessions();
      scheduleReconnect();
    });
    reconnectAttempt = 0;
    replayPendingCaptures();
    replayImageSessions();
    return connectedPort;
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
    if (!nativePort || !imageSessions.has(session.captureID) || session.awaitingReplay) return;
    const next = session.ledger.next();
    if (!next) return;
    try {
      nativePort.postMessage(next.message);
    } catch {
      session.awaitingReplay = true;
      nativePort = null;
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
        bytes,
        messages,
        createdAt: Date.now(),
        replayAttempts: 0,
        awaitingReplay: false,
      };
      imageSessions.set(session.captureID, session);
      setTimeout(() => {
        const current = imageSessions.get(session.captureID);
        if (current === session && Date.now() - session.createdAt >= MAX_STORE_TTL_MS) {
          failImageSession(session, 'image-transfer-expired');
        }
      }, MAX_STORE_TTL_MS + 1);
      pumpImageSession(session);
      return session;
    });
  }

  function executeMainStoreStart(tabID, frameID, descriptor, mode) {
    if (!descriptor || !chrome.scripting || typeof chrome.scripting.executeScript !== 'function') return Promise.resolve(null);
    return executeScriptAwait({
      target: { tabId: tabID, frameIds: [frameID] },
      world: 'MAIN',
      args: [
        {
          url: descriptor.url || null,
          pageURL: descriptor.pageURL || '',
          sourcePoint: descriptor.sourcePoint || null,
          domSourceKind: descriptor.domSourceKind || 'image',
          mimeType: descriptor.mimeType || null,
          mode,
          captureID: descriptor.captureID || '',
        },
      ],
      func: async (request) => {
        const MAX_BYTES = 50 * 1024 * 1024;
        const CHUNK_BYTES = 512 * 1024;
        const stores = globalThis.__PROMPTSTUDIO_IMAGE_BYTE_STORES__ || new Map();
        globalThis.__PROMPTSTUDIO_IMAGE_BYTE_STORES__ = stores;
        for (const [id, entry] of stores) if (Date.now() >= entry.expiresAt) stores.delete(id);
        if (stores.size) return null;
        const dataBytes = async (value) => {
          if (typeof value !== 'string' || !/^data:/i.test(value)) return null;
          const comma = value.indexOf(',');
          if (comma < 0) return null;
          const metadata = value.slice(0, comma);
          const payload = value.slice(comma + 1);
          if (/;base64/i.test(metadata)) {
            const binary = atob(payload);
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
            return bytes;
          }
          return new TextEncoder().encode(decodeURIComponent(payload));
        };
        const elementAtPoint = () => {
          const point = request.sourcePoint;
          let element = point && document.elementFromPoint(Number(point.x) || 0, Number(point.y) || 0);
          if (element && element.closest) element = element.closest('img, picture, canvas, svg, *') || element;
          if (!element && request.url && document.images) element = Array.from(document.images).find((candidate) => candidate.currentSrc === request.url || candidate.src === request.url);
          return element;
        };
        let bytes = null;
        let mimeType = request.mimeType || null;
        if (request.mode === 'pageContext' && request.url && !/^data:/i.test(request.url)) {
          try {
            const response = await fetch(request.url, { credentials: 'include', referrer: request.pageURL || undefined });
            if (response.ok) {
              bytes = new Uint8Array(await response.arrayBuffer());
              mimeType = response.headers.get('content-type') || mimeType;
            }
          } catch { bytes = null; }
        }
        if (request.mode === 'loadedBytes') {
          bytes = await dataBytes(request.url);
          const element = elementAtPoint();
          if (!bytes && element && typeof element.toBlob === 'function') {
            try { const blob = await new Promise((resolve) => element.toBlob(resolve, 'image/png')); bytes = blob ? new Uint8Array(await blob.arrayBuffer()) : null; mimeType = 'image/png'; } catch { bytes = null; }
          }
          if (!bytes && element && String(element.tagName || '').toLowerCase() === 'svg' && element.outerHTML) {
            bytes = new TextEncoder().encode(element.outerHTML);
            mimeType = 'image/svg+xml';
          }
          if (!bytes && request.url && /^blob:/i.test(request.url)) {
            try { const response = await fetch(request.url); bytes = response.ok ? new Uint8Array(await response.arrayBuffer()) : null; mimeType = response.headers.get('content-type') || mimeType; } catch { bytes = null; }
          }
        }
        if (!bytes || bytes.byteLength > MAX_BYTES) return null;
        const storeID = `${request.captureID || 'image'}-${request.mode}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
        stores.set(storeID, { bytes, mimeType, expiresAt: Date.now() + 300_000 });
        return { storeID, byteCount: bytes.byteLength, mimeType };
      },
    });
  }

  async function captureVisibleTabCrop(tab, frameID, descriptor) {
    if (!tab || !descriptor || !descriptor.screenRect || typeof chrome.tabs.captureVisibleTab !== 'function') return null;
    const screenshot = await new Promise((resolve) => {
      try {
        chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' }, (dataURL) => resolve(dataURL || null));
      } catch {
        resolve(null);
      }
    });
    if (!screenshot) return null;
    if (typeof OffscreenCanvas === 'function' && typeof createImageBitmap === 'function') {
      try {
        const response = await fetch(screenshot);
        const bitmap = await createImageBitmap(await response.blob());
        const crop = image.cropRectFromScreenRect(
          descriptor.screenRect,
          descriptor.topMetrics || {},
          (descriptor.topMetrics && descriptor.topMetrics.devicePixelRatio) || descriptor.devicePixelRatio || 1,
          { width: bitmap.width, height: bitmap.height },
        );
        if (!crop.width || !crop.height) { bitmap.close(); return null; }
        const canvas = new OffscreenCanvas(crop.width, crop.height);
        const context = canvas.getContext('2d');
        context.drawImage(bitmap, crop.left, crop.top, crop.width, crop.height, 0, 0, crop.width, crop.height);
        const blob = await canvas.convertToBlob({ type: 'image/png' });
        bitmap.close();
        return { bytes: new Uint8Array(await blob.arrayBuffer()), mimeType: 'image/png' };
      } catch { /* fall through to bounded chunk bridge */ }
    }
    const captureID = descriptor.captureID || `screenshot-${Date.now()}`;
    const crop = image.cropRectFromScreenRect(
      descriptor.screenRect,
      descriptor.topMetrics || {},
      (descriptor.topMetrics && descriptor.topMetrics.devicePixelRatio) || descriptor.devicePixelRatio || 1,
      descriptor.screenshotSize || null,
    );
    if (!crop.width || !crop.height) return null;
    const chunkSize = 512 * 1024;
    const chunks = [];
    for (let offset = 0; offset < screenshot.length; offset += chunkSize) chunks.push(screenshot.slice(offset, offset + chunkSize));
    if (chunks.some((chunk) => JSON.stringify({ data: chunk }).length >= image.IMAGE_FRAME_MAX_BYTES)) return null;
    const started = await sendToFrameAwait(tab.id, frameID, {
      type: 'cropImageScreenshotStart', captureID, totalChunks: chunks.length, crop,
      screenRect: descriptor.screenRect, topMetrics: descriptor.topMetrics,
      devicePixelRatio: descriptor.devicePixelRatio,
    });
    if (!started || !started.ok) return null;
    for (let index = 0; index < chunks.length; index += 1) {
      const accepted = await sendToFrameAwait(tab.id, frameID, { type: 'cropImageScreenshotChunk', captureID, index, data: chunks[index] });
      if (!accepted || !accepted.ok) return null;
    }
    const result = await sendToFrameAwait(tab.id, frameID, { type: 'cropImageScreenshotEnd', captureID });
    if (!result || !result.ok) return null;
    return readContentStore(tab.id, frameID, result);
  }

  async function acquireDescriptorBytes(tab, frameID, descriptor) {
    let captureDescriptor = descriptor;
    if (!captureDescriptor.topMetrics) {
      const topMetrics = await sendToFrameAwait(tab.id, 0, { type: 'getTopViewportMetrics' });
      if (topMetrics && topMetrics.ok) captureDescriptor = { ...captureDescriptor, topMetrics };
    }
    let acquired = null;
    const pageStore = await executeMainStoreStart(tab.id, frameID, captureDescriptor, 'pageContext');
    if (pageStore) acquired = await readFrameStore(tab.id, frameID, pageStore);
    let acquisitionMethod = 'pageContext';
    if (!acquired && captureDescriptor.url && !/^(?:data|blob):/i.test(captureDescriptor.url)) {
      try {
        const response = await fetch(captureDescriptor.url, { credentials: 'include', referrer: captureDescriptor.pageURL || undefined });
        if (response.ok) acquired = { bytes: new Uint8Array(await response.arrayBuffer()), mimeType: response.headers.get('content-type') || captureDescriptor.mimeType || null };
      } catch { acquired = null; }
      acquisitionMethod = 'extensionFetch';
    }
    if (!acquired) {
      const loadedStore = await executeMainStoreStart(tab.id, frameID, captureDescriptor, 'loadedBytes');
      if (loadedStore) acquired = await readFrameStore(tab.id, frameID, loadedStore);
      acquisitionMethod = 'loadedBytes';
    }
    if (!acquired) {
      acquired = await captureVisibleTabCrop(tab, frameID, captureDescriptor);
      acquisitionMethod = 'screenshot';
    }
    if (!acquired || !acquired.bytes) throw new Error('image-acquisition-failed');
    image.assertImageSize(acquired.bytes);
    const sha256 = await image.sha256Hex(acquired.bytes);
    return {
      candidate: image.makeImageCandidate({ ...captureDescriptor, acquisitionMethod, isScreenshot: acquisitionMethod === 'screenshot', mimeType: acquired.mimeType || captureDescriptor.mimeType, byteCount: acquired.bytes.byteLength, sha256 }),
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

  function postDragPreview(session, { drop = false, sequence = session.latestSequence } = {}) {
    if (!nativePort || session.previewPending || !session.latestPoint) return;
    if (!Number.isInteger(Number(sequence)) || Number(sequence) <= 0) return;
    session.previewPending = true;
    session.pendingPreviews.set(Number(sequence), { final: Boolean(drop), createdAt: Date.now() });
    try {
      nativePort.postMessage({
        type: 'imageDragPreview', origin: originForRuntime(), captureID: session.captureID,
        screenPoint: session.latestPoint, insidePet: session.insidePet, drop: Boolean(drop),
        sequence: Number(sequence),
      });
    } catch {
      session.previewPending = false;
      session.pendingPreviews.delete(Number(sequence));
      sendToFrame(session.tabID, session.frameID, { type: 'imageCaptureResult', result: { type: 'failed', captureID: session.captureID, code: 'native-host-unavailable' } });
      scheduleReconnect();
    }
  }

  function pumpDragPreview(session) {
    if (!session.latestPoint || session.previewPending) return;
    if (session.finalPending && Number.isInteger(session.finalSequence)) {
      postDragPreview(session, { drop: true, sequence: session.finalSequence });
    } else {
      postDragPreview(session);
    }
  }

  async function startDrag(tabID, frameID, descriptor) {
    if (!Number.isInteger(tabID) || imageSessions.size || dragSessions.size || pendingImageStarts.size) throw new Error('image-busy');
    const session = {
      captureID: descriptor.captureID,
      tabID,
      frameID,
      descriptor,
      bytesPromise: null,
      latestPoint: null,
      latestSequence: 0,
      insidePet: false,
      previewPending: false,
      pendingPreviews: new Map(),
      finalSequence: null,
      finalPending: false,
    };
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
    if (session) dragSessions.delete(captureID);
    if (nativePort) {
      try { nativePort.postMessage({ type: 'imageDragCancel', origin: originForRuntime(), captureID }); } catch { /* disconnect cleanup handles it */ }
    }
  }

  function beginDragPreview(captureID, screenPoint, sequence) {
    if (!captureID || !screenPoint || !Number.isInteger(Number(sequence)) || Number(sequence) <= 0) return false;
    if (!nativePort && !connectNative()) return false;
    try {
      nativePort.postMessage({
        type: 'imageDragPreview', origin: originForRuntime(), captureID,
        screenPoint, insidePet: false, drop: false, sequence: Number(sequence),
      });
      return true;
    } catch {
      scheduleReconnect();
      return false;
    }
  }

  function finalizeDrag(captureID, sequence, screenPoint) {
    const session = dragSessions.get(captureID);
    const finalSequence = Number(sequence);
    if (!session || !Number.isInteger(finalSequence) || finalSequence <= session.latestSequence || session.finalPending) return false;
    session.latestPoint = screenPoint || session.latestPoint;
    session.latestSequence = finalSequence;
    session.finalSequence = finalSequence;
    session.finalPending = true;
    postDragPreview(session, { drop: true, sequence: finalSequence });
    setTimeout(() => {
      const current = dragSessions.get(captureID);
      if (!current || !current.finalPending || current.finalSequence !== finalSequence) return;
      current.finalPending = false;
      current.pendingPreviews.delete(finalSequence);
      sendToFrame(current.tabID, current.frameID, {
        type: 'imageCaptureResult',
        result: { type: 'imageDragPreviewAck', captureID, sequence: finalSequence, insidePet: false, code: 'final-hit-timeout' },
      });
    }, FINAL_HIT_TIMEOUT_MS);
    return true;
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
    if (message && message.type === 'beginImageDragPreview') {
      sendResponse({ ok: beginDragPreview(message.captureID, message.screenPoint, message.sequence) });
      return false;
    }
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
      const sequence = Number(message.sequence);
      if (!Number.isInteger(sequence) || sequence <= session.latestSequence) {
        sendResponse({ ok: false, code: 'stale-preview-sequence' });
        return false;
      }
      session.latestSequence = sequence;
      session.insidePet = Boolean(message.insidePet);
      pumpDragPreview(session);
      sendResponse({ ok: true });
      return false;
    }
    if (message && message.type === 'finalizeImageDrag') {
      sendResponse({ ok: finalizeDrag(message.captureID, message.sequence, message.screenPoint) });
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
  // Connect lazily from an explicit capture/drag request. Starting a service
  // worker must not create a Chrome-visible error merely because PromptStudio
  // is not running yet.
}());
