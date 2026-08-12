(function exposeBackgroundLogic(global) {
  const CAPTURE_TTL_MS = 60_000;
  const MAX_RETRY_ATTEMPTS = 4;
  const TERMINAL_TYPES = new Set(['saved', 'cancelled', 'failed']);

  function isTerminalCaptureType(type) {
    return TERMINAL_TYPES.has(type);
  }

  class PendingCaptureLedger {
    constructor({ now = Date.now } = {}) {
      this.now = typeof now === 'function' ? now : () => Date.now();
      this.entries = new Map();
    }

    add(candidate, tabID, now = this.now()) {
      this.entries.set(candidate.captureID, {
        candidate,
        tabID,
        createdAt: now,
        expiresAt: now + CAPTURE_TTL_MS,
        attempts: 0,
      });
    }

    markSent(captureID, now = this.now()) {
      const entry = this.entries.get(captureID);
      if (!entry || now >= entry.expiresAt || entry.attempts >= MAX_RETRY_ATTEMPTS) return false;
      entry.attempts += 1;
      return true;
    }

    receive(response, now = this.now()) {
      if (!response || !response.captureID || !this.entries.has(response.captureID)) return false;
      if (isTerminalCaptureType(response.type)) this.entries.delete(response.captureID);
      else if (now >= this.entries.get(response.captureID).expiresAt) this.entries.delete(response.captureID);
      return true;
    }

    replayable(now = this.now()) {
      this.expire(now);
      return [...this.entries.values()].filter((entry) => entry.attempts < MAX_RETRY_ATTEMPTS);
    }

    expire(now = this.now()) {
      for (const [captureID, entry] of this.entries) {
        if (now >= entry.expiresAt) this.entries.delete(captureID);
      }
    }

    has(captureID) {
      return this.entries.has(captureID);
    }
  }

  const api = { CAPTURE_TTL_MS, MAX_RETRY_ATTEMPTS, isTerminalCaptureType, PendingCaptureLedger };
  global.PromptStudioBackgroundLogic = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
}(typeof globalThis !== 'undefined' ? globalThis : this));
