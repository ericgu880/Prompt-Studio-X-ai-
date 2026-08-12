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
        dragSession.previewPending = false;
        const previewResponse = {
          ...response,
          sequence: Number.isInteger(Number(response.sequence))
            ? Number(response.sequence) : dragSession.latestSequence,
        };
        sendToFrame(dragSession.tabID, dragSession.frameID, { type: 'imageCaptureResult', result: previewResponse });
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
    nativePort.onMessage.addListener(routeNativeResponse);
    nativePort.onDisconnect.addListener(() => {
      nativePort = null;
      failDisconnectedImageSessions();
      scheduleReconnect();
    });
    reconnectAttempt = 0;
    replayPendingCaptures();
    replayImageSessions();
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
    if (!tab || !descriptor || !descriptor.crop || descriptor.crop.width <= 0 || descriptor.crop.height <= 0
        || typeof chrome.tabs.captureVisibleTab !== 'function') return null;
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
        const crop = descriptor.crop;
        const canvas = new OffscreenCanvas(crop.width, crop.height);
        const context = canvas.getContext('2d');
        context.drawImage(bitmap, crop.left, crop.top, crop.width, crop.height, 0, 0, crop.width, crop.height);
        const blob = await canvas.convertToBlob({ type: 'image/png' });
        bitmap.close();
        return { bytes: new Uint8Array(await blob.arrayBuffer()), mimeType: 'image/png' };
      } catch { /* fall through to bounded chunk bridge */ }
    }
    const captureID = descriptor.captureID || `screenshot-${Date.now()}`;
    const chunkSize = 512 * 1024;
    const chunks = [];
    for (let offset = 0; offset < screenshot.length; offset += chunkSize) chunks.push(screenshot.slice(offset, offset + chunkSize));
    if (chunks.some((chunk) => JSON.stringify({ data: chunk }).length >= image.IMAGE_FRAME_MAX_BYTES)) return null;
    const started = await sendToFrameAwait(tab.id, frameID, {
      type: 'cropImageScreenshotStart', captureID, totalChunks: chunks.length, crop: descriptor.crop,
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
    let acquired = null;
    const pageStore = await executeMainStoreStart(tab.id, frameID, descriptor, 'pageContext');
    if (pageStore) acquired = await readFrameStore(tab.id, frameID, pageStore);
    let acquisitionMethod = 'pageContext';
    if (!acquired && descriptor.url && !/^(?:data|blob):/i.test(descriptor.url)) {
      try {
        const response = await fetch(descriptor.url, { credentials: 'include', referrer: descriptor.pageURL || undefined });
        if (response.ok) acquired = { bytes: new Uint8Array(await response.arrayBuffer()), mimeType: response.headers.get('content-type') || descriptor.mimeType || null };
      } catch { acquired = null; }
      acquisitionMethod = 'extensionFetch';
    }
    if (!acquired) {
      const loadedStore = await executeMainStoreStart(tab.id, frameID, descriptor, 'loadedBytes');
      if (loadedStore) acquired = await readFrameStore(tab.id, frameID, loadedStore);
      acquisitionMethod = 'loadedBytes';
    }
    if (!acquired) {
      acquired = await captureVisibleTabCrop(tab, frameID, descriptor);
      acquisitionMethod = 'screenshot';
    }
    if (!acquired || !acquired.bytes) throw new Error('image-acquisition-failed');
    image.assertImageSize(acquired.bytes);
    const sha256 = await image.sha256Hex(acquired.bytes);
    return {
      candidate: image.makeImageCandidate({ ...descriptor, acquisitionMethod, isScreenshot: acquisitionMethod === 'screenshot', mimeType: acquired.mimeType || descriptor.mimeType, byteCount: acquired.bytes.byteLength, sha256 }),
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
      nativePort.postMessage({
        type: 'imageDragPreview', origin: originForRuntime(), captureID: session.captureID,
        screenPoint: session.latestPoint, insidePet: session.insidePet, drop: false,
        sequence: session.latestSequence,
      });
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
      if (Number.isInteger(Number(message.sequence))) session.latestSequence = Number(message.sequence);
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
