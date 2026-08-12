(function runPromptStudioBackground() {
  importScripts('background-logic.js');
  const HOST_NAME = 'com.creatigo.promptstudio.capture';
  const logic = globalThis.PromptStudioBackgroundLogic;
  const ledger = new logic.PendingCaptureLedger();
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

  function connectNative() {
    if (nativePort) return nativePort;
    try {
      nativePort = chrome.runtime.connectNative(HOST_NAME);
    } catch {
      nativePort = null;
      scheduleReconnect();
      return null;
    }
    nativePort.onMessage.addListener((response) => {
      const captureID = response && response.captureID;
      const entry = captureID && ledger.entries.get(captureID);
      if (entry && Number.isInteger(entry.tabID)) {
        chrome.tabs.sendMessage(entry.tabID, { type: 'captureResult', result: response });
      }
      ledger.receive(response);
    });
    nativePort.onDisconnect.addListener(() => {
      nativePort = null;
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

  function sendCandidate(candidate, tabID) {
    const port = connectNative();
    ledger.add(candidate, tabID);
    // Keep the in-memory pending set bounded even if the browser never reconnects
    // and no terminal response arrives.
    setTimeout(() => ledger.expire(Date.now()), logic.CAPTURE_TTL_MS + 1);
    if (!port || !ledger.markSent(candidate.captureID)) throw new Error('native-host-unavailable');
    port.postMessage({
      type: 'capture',
      origin: originForRuntime(),
      candidate,
    });
  }

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || message.type !== 'captureCandidate' || !message.candidate) return false;
    const tabID = sender.tab && sender.tab.id;
    if (!Number.isInteger(tabID)) {
      sendResponse({ ok: false, code: 'missing-tab' });
      return false;
    }
    try {
      sendCandidate(message.candidate, tabID);
      sendResponse({ ok: true });
    } catch {
      sendResponse({ ok: false, code: 'native-host-unavailable' });
      scheduleReconnect();
    }
    return false;
  });

  connectNative();
}());
