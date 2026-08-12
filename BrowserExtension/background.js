(function runPromptStudioBackground() {
  const HOST_NAME = 'com.creatigo.promptstudio.capture';
  const pendingTabs = new Map();
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
      const tabID = pendingTabs.get(captureID);
      if (captureID) pendingTabs.delete(captureID);
      if (Number.isInteger(tabID)) {
        chrome.tabs.sendMessage(tabID, { type: 'captureResult', result: response });
      }
    });
    nativePort.onDisconnect.addListener(() => {
      nativePort = null;
      scheduleReconnect();
    });
    reconnectAttempt = 0;
    return nativePort;
  }

  function sendCandidate(candidate, tabID) {
    const port = connectNative();
    if (!port) throw new Error('native-host-unavailable');
    pendingTabs.set(candidate.captureID, tabID);
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
