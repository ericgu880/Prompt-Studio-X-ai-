/*
 * Pure image-capture helpers shared by the MV3 content/background scripts and Node tests.
 * The module deliberately has no Chrome dependency.  Browser orchestration supplies the
 * fetch/screenshot seams so that a user action is the only point at which bytes are read.
 */
(function exposeImageCapture(global) {
  const MAX_IMAGE_BYTES = 50 * 1024 * 1024;
  const IMAGE_CHUNK_BYTES = 512 * 1024;
  const IMAGE_FRAME_MAX_BYTES = 1024 * 1024;
  const VALID_DOM_SOURCE_KINDS = new Set([
    'image', 'picture', 'srcset', 'dataURL', 'blob', 'canvas', 'inlineSVG', 'cssBackground',
  ]);
  const VALID_ACQUISITION_METHODS = new Set(['pageContext', 'extensionFetch', 'loadedBytes', 'screenshot']);

  function finiteNumber(value, fallback = 0) {
    const number = Number(value);
    return Number.isFinite(number) ? number : fallback;
  }

  function positiveNumber(value, fallback = 1) {
    const number = finiteNumber(value, fallback);
    return number > 0 ? number : fallback;
  }

  function toUint8Array(value) {
    if (value == null) return null;
    if (value instanceof Uint8Array) return value;
    if (typeof Buffer !== 'undefined' && Buffer.isBuffer(value)) {
      return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    }
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    return null;
  }

  async function responseBytes(value) {
    if (value == null) return null;
    const direct = toUint8Array(value);
    if (direct) return direct;
    if (value instanceof Blob && typeof value.arrayBuffer === 'function') {
      return new Uint8Array(await value.arrayBuffer());
    }
    if (typeof value.arrayBuffer === 'function') {
      if ('ok' in value && value.ok === false) return null;
      return new Uint8Array(await value.arrayBuffer());
    }
    if (value.bytes != null) return responseBytes(value.bytes);
    return null;
  }

  function assertImageSize(bytes) {
    const normalized = toUint8Array(bytes);
    if (!normalized) throw new TypeError('image bytes are required');
    if (normalized.byteLength > MAX_IMAGE_BYTES) throw new Error('image exceeds 50 MiB');
    return normalized;
  }

  function sanitizeResourceURL(rawURL, baseURL) {
    if (typeof rawURL !== 'string' || !rawURL.trim()) return null;
    try {
      const value = new URL(rawURL, baseURL || undefined);
      value.username = '';
      value.password = '';
      value.hash = '';
      return value.href;
    } catch {
      // Keep data/blob URLs usable even when URL's base is unavailable.  Never include a
      // fragment or credentials in candidate metadata.
      const value = rawURL.trim().replace(/#.*$/, '');
      return value || null;
    }
  }

  function isDataURL(value) {
    return typeof value === 'string' && /^data:image\//i.test(value.trim());
  }

  function isBlobURL(value) {
    return typeof value === 'string' && /^blob:/i.test(value.trim());
  }

  function classifyImageSource(value, { kind, tagName } = {}) {
    const normalizedKind = typeof kind === 'string' && VALID_DOM_SOURCE_KINDS.has(kind) ? kind : null;
    if (normalizedKind) return { domSourceKind: normalizedKind, url: value || null };
    const source = typeof value === 'string' ? value.trim() : '';
    if (isDataURL(source)) return { domSourceKind: 'dataURL', url: source };
    if (isBlobURL(source)) return { domSourceKind: 'blob', url: source };
    if (String(tagName || '').toLowerCase() === 'svg') return { domSourceKind: 'inlineSVG', url: null };
    return { domSourceKind: 'image', url: source || null };
  }

  // Split on commas outside url(...), which is enough for normal srcset and data URLs while
  // remaining safe for URLs containing query strings or parentheses.
  function splitCommaList(value) {
    const pieces = [];
    let start = 0;
    let depth = 0;
    let quote = '';
    const source = String(value || '');
    for (let index = 0; index < source.length; index += 1) {
      const character = source[index];
      if (quote) {
        if (character === quote && source[index - 1] !== '\\') quote = '';
      } else if (character === '"' || character === "'") {
        quote = character;
      } else if (character === '(') {
        depth += 1;
      } else if (character === ')' && depth > 0) {
        depth -= 1;
      } else if (character === ',' && depth === 0) {
        pieces.push(source.slice(start, index).trim());
        start = index + 1;
      }
    }
    pieces.push(source.slice(start).trim());
    return pieces.filter(Boolean);
  }

  function parseSrcset(srcset) {
    const candidates = [];
    for (const part of splitCommaList(srcset)) {
      const tokens = part.trim().split(/\s+/);
      const url = tokens.shift();
      if (!url) continue;
      const descriptors = tokens.filter(Boolean);
      if (descriptors.length > 1) continue;
      if (!descriptors.length) {
        candidates.push({ url, width: null, density: 1, descriptor: '' });
        continue;
      }
      const descriptor = descriptors[0];
      const widthMatch = /^(\d+)w$/.exec(descriptor);
      const densityMatch = /^(\d+(?:\.\d+)?)x$/.exec(descriptor);
      if (widthMatch && Number(widthMatch[1]) > 0) {
        candidates.push({ url, width: Number(widthMatch[1]), density: null, descriptor });
      } else if (densityMatch && Number(densityMatch[1]) > 0) {
        candidates.push({ url, width: null, density: Number(densityMatch[1]), descriptor });
      }
    }
    return candidates;
  }

  function candidateEffectivePixels(candidate, { viewportWidth = 1, devicePixelRatio = 1 } = {}) {
    if (!candidate) return 0;
    if (Number.isFinite(candidate.width)) return candidate.width;
    return positiveNumber(candidate.density, 1) * positiveNumber(viewportWidth, 1) * positiveNumber(devicePixelRatio, 1);
  }

  function selectSrcsetCandidate(candidates, context = {}) {
    const values = Array.isArray(candidates) ? candidates.filter((candidate) => candidate && candidate.url) : [];
    if (!values.length) return null;
    // The requested behavior is deterministic and intentionally favors the highest-resolution
    // source.  For width descriptors the viewport gives a physical-pixel comparison; density
    // descriptors already encode the multiplier.
    return values.slice().sort((left, right) => {
      const difference = candidateEffectivePixels(right, context) - candidateEffectivePixels(left, context);
      return difference || String(left.url).localeCompare(String(right.url));
    })[0];
  }

  function selectImageURL({ currentSrc, src, srcset, sources, viewportWidth, devicePixelRatio, allowCurrentSrc = true } = {}) {
    if (allowCurrentSrc && typeof currentSrc === 'string' && currentSrc.trim()) return currentSrc.trim();
    const sourceCandidates = [];
    if (Array.isArray(sources)) {
      for (const source of sources) sourceCandidates.push(...parseSrcset(source && source.srcset));
    }
    sourceCandidates.push(...parseSrcset(srcset));
    const selected = selectSrcsetCandidate(sourceCandidates, { viewportWidth, devicePixelRatio });
    return selected ? selected.url : (typeof src === 'string' && src.trim() ? src.trim() : null);
  }

  function parseCSSBackgroundImages(backgroundImage) {
    const images = [];
    const source = String(backgroundImage || '');
    const matcher = /url\(\s*(?:(["'])(.*?)\1|([^)]*?))\s*\)/gi;
    let match;
    while ((match = matcher.exec(source))) {
      const value = (match[2] !== undefined ? match[2] : match[3] || '').trim();
      // All URL forms are valid CSS image layers.  Empty and non-url layers were filtered by
      // the parser; preserving data/blob/relative/absolute values lets acquisition decide.
      if (value) images.push(value);
    }
    return images;
  }

  function cropRectForVisibleElement(elementRect, viewport, devicePixelRatio = 1) {
    const rect = elementRect || {};
    const viewportWidth = Math.max(0, finiteNumber(viewport && viewport.width));
    const viewportHeight = Math.max(0, finiteNumber(viewport && viewport.height));
    const left = Math.max(0, Math.min(viewportWidth, finiteNumber(rect.left)));
    const top = Math.max(0, Math.min(viewportHeight, finiteNumber(rect.top)));
    const right = Math.max(left, Math.min(viewportWidth, finiteNumber(rect.right, left)));
    const bottom = Math.max(top, Math.min(viewportHeight, finiteNumber(rect.bottom, top)));
    const dpr = positiveNumber(devicePixelRatio, 1);
    return {
      left: Math.round(left * dpr),
      top: Math.round(top * dpr),
      width: Math.round(Math.max(0, right - left) * dpr),
      height: Math.round(Math.max(0, bottom - top) * dpr),
    };
  }

  function resolveImageDescriptor(element, {
    viewportWidth,
    devicePixelRatio,
    allowCSSBackground = false,
    baseURL,
  } = {}) {
    if (!element) return null;
    const tagName = String(element.tagName || element.nodeName || '').toLowerCase();
    const currentSrc = typeof element.currentSrc === 'string' ? element.currentSrc.trim() : '';
    const srcset = typeof element.srcset === 'string' ? element.srcset : '';
    const sourceElements = Array.isArray(element.sources)
      ? element.sources
      : (element.querySelectorAll ? Array.from(element.querySelectorAll('source')) : []);
    if (currentSrc) {
      const source = classifyImageSource(currentSrc, { tagName, kind: tagName === 'picture' ? 'picture' : undefined });
      return { ...source, url: sanitizeResourceURL(currentSrc, baseURL), currentSrc: true, element };
    }
    const srcsetCandidate = selectSrcsetCandidate([
      ...sourceElements.flatMap((source) => parseSrcset(source && source.srcset)),
      ...parseSrcset(srcset),
    ], { viewportWidth, devicePixelRatio });
    if (srcsetCandidate) {
      return {
        ...classifyImageSource(srcsetCandidate.url, { kind: 'srcset' }),
        url: sanitizeResourceURL(srcsetCandidate.url, baseURL),
        srcsetCandidate,
        element,
      };
    }
    const src = typeof element.src === 'string' ? element.src.trim() : '';
    if (src) return { ...classifyImageSource(src, { tagName }), url: sanitizeResourceURL(src, baseURL), element };
    if (tagName === 'canvas' || typeof element.toDataURL === 'function') {
      return { domSourceKind: 'canvas', url: null, loadedBytes: element, element };
    }
    if (tagName === 'svg' || typeof element.outerHTML === 'string' && /^\s*<svg(?:\s|>)/i.test(element.outerHTML)) {
      return { domSourceKind: 'inlineSVG', url: null, svgText: element.outerHTML || '', element };
    }
    if (allowCSSBackground) {
      let style = element.computedStyle || element.style || {};
      if ((!style.backgroundImage && !style['background-image']) && typeof getComputedStyle === 'function') {
        try { style = getComputedStyle(element); } catch { /* detached or restricted element */ }
      }
      const layers = parseCSSBackgroundImages(style.backgroundImage || style['background-image'] || '');
      if (layers.length) {
        const url = layers[0];
        return {
          domSourceKind: 'cssBackground',
          url: sanitizeResourceURL(url, baseURL),
          backgroundLayers: layers.map((layer) => sanitizeResourceURL(layer, baseURL)).filter(Boolean),
          element,
        };
      }
    }
    return null;
  }

  function selectDOMImageMetadata(element, options = {}) {
    return resolveImageDescriptor(element, options);
  }

  async function defaultPageContextFetch(url, { pageURL } = {}) {
    if (typeof fetch !== 'function' || !url) return null;
    try {
      const response = await fetch(url, { credentials: 'include', referrer: pageURL || undefined });
      return response.ok === false ? null : response;
    } catch {
      return null;
    }
  }

  async function defaultExtensionFetch(url) {
    if (typeof fetch !== 'function' || !url || /^(?:data|blob):/i.test(url)) return null;
    try {
      const response = await fetch(url, { credentials: 'include' });
      return response.ok === false ? null : response;
    } catch {
      return null;
    }
  }

  async function acquireImageBytes(descriptor = {}, seams = {}) {
    const url = descriptor.url || descriptor.resourceURL || null;
    const pageFetcher = seams.pageContextFetch || defaultPageContextFetch;
    const extensionFetcher = seams.extensionFetch || defaultExtensionFetch;
    const loadedFetcher = seams.loadedBytes || (async () => responseBytes(descriptor.loadedBytes));
    const screenshotFetcher = seams.screenshot || (async () => null);
    const attempts = [
      ['pageContext', () => pageFetcher(url, { pageURL: descriptor.pageURL, descriptor })],
      ['extensionFetch', () => extensionFetcher(url, { descriptor })],
      ['loadedBytes', () => loadedFetcher(descriptor)],
      ['screenshot', () => screenshotFetcher(descriptor)],
    ];
    for (const [acquisitionMethod, attempt] of attempts) {
      let result = null;
      try { result = await attempt(); } catch { result = null; }
      const bytes = await responseBytes(result);
      if (!bytes) continue;
      const normalized = assertImageSize(bytes);
      return {
        bytes: normalized,
        acquisitionMethod,
        isScreenshot: acquisitionMethod === 'screenshot',
        mimeType: result && result.headers && typeof result.headers.get === 'function'
          ? result.headers.get('content-type') || null : descriptor.mimeType || null,
      };
    }
    throw new Error('image-acquisition-failed');
  }

  async function sha256Hex(bytes) {
    const normalized = assertImageSize(bytes);
    const subtle = global.crypto && global.crypto.subtle
      ? global.crypto.subtle
      : (typeof require === 'function' ? require('node:crypto').webcrypto.subtle : null);
    if (!subtle) throw new Error('sha256-unavailable');
    const digest = await subtle.digest('SHA-256', normalized);
    return Array.from(new Uint8Array(digest), (value) => value.toString(16).padStart(2, '0')).join('');
  }

  function encodeBase64(bytes) {
    const normalized = toUint8Array(bytes);
    if (!normalized) throw new TypeError('bytes are required');
    if (typeof Buffer !== 'undefined') return Buffer.from(normalized).toString('base64');
    let binary = '';
    const step = 0x8000;
    for (let index = 0; index < normalized.length; index += step) {
      binary += String.fromCharCode(...normalized.subarray(index, index + step));
    }
    return btoa(binary);
  }

  function decodeBase64(value) {
    if (typeof value !== 'string') throw new TypeError('base64 is required');
    if (typeof Buffer !== 'undefined') return new Uint8Array(Buffer.from(value, 'base64'));
    const binary = atob(value);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  }

  function imageChunks(bytes) {
    const normalized = assertImageSize(bytes);
    const chunks = [];
    for (let offset = 0, index = 0; offset < normalized.byteLength; offset += IMAGE_CHUNK_BYTES, index += 1) {
      const raw = normalized.subarray(offset, Math.min(normalized.byteLength, offset + IMAGE_CHUNK_BYTES));
      const base64Data = encodeBase64(raw);
      // 512 KiB raw bytes encode to ~699 KiB, leaving room for the JSON envelope under 1 MiB.
      if (base64Data.length >= IMAGE_FRAME_MAX_BYTES) throw new Error('image chunk frame exceeds 1 MiB');
      chunks.push({ index, byteCount: raw.byteLength, base64Data });
    }
    return chunks;
  }

  function makeImageCandidate(values = {}) {
    const domSourceKind = VALID_DOM_SOURCE_KINDS.has(values.domSourceKind) ? values.domSourceKind : 'image';
    const acquisitionMethod = VALID_ACQUISITION_METHODS.has(values.acquisitionMethod) ? values.acquisitionMethod : 'pageContext';
    const byteCount = Math.max(0, Math.floor(finiteNumber(values.byteCount)));
    return {
      captureID: String(values.captureID || ''),
      pageTitle: typeof values.pageTitle === 'string' ? values.pageTitle : '',
      pageURL: typeof values.pageURL === 'string' ? values.pageURL : '',
      siteName: typeof values.siteName === 'string' ? values.siteName : '',
      resourceURL: sanitizeResourceURL(values.resourceURL, values.pageURL),
      altText: typeof values.altText === 'string' ? values.altText : '',
      originalFileName: typeof values.originalFileName === 'string' ? values.originalFileName : '',
      domSourceKind,
      acquisitionMethod,
      isScreenshot: Boolean(values.isScreenshot || acquisitionMethod === 'screenshot'),
      mimeType: typeof values.mimeType === 'string' && values.mimeType ? values.mimeType : null,
      byteCount,
      sha256: typeof values.sha256 === 'string' ? values.sha256.toLowerCase() : '',
      pixelWidth: Number.isFinite(Number(values.pixelWidth)) ? Number(values.pixelWidth) : null,
      pixelHeight: Number.isFinite(Number(values.pixelHeight)) ? Number(values.pixelHeight) : null,
      clickScreenPoint: {
        x: finiteNumber(values.clickScreenPoint && values.clickScreenPoint.x),
        y: finiteNumber(values.clickScreenPoint && values.clickScreenPoint.y),
      },
      capturedAt: typeof values.capturedAt === 'string' && values.capturedAt ? values.capturedAt : new Date().toISOString(),
    };
  }

  function buildImageMessages({ origin, candidate = {}, bytes }) {
    if (!origin) throw new Error('image origin is required');
    const normalized = assertImageSize(bytes);
    const chunks = imageChunks(normalized);
    const byteCount = normalized.byteLength;
    const sha256 = candidate.sha256 || '';
    const captureID = String(candidate.captureID || '');
    if (!captureID) throw new Error('image capture ID is required');
    const completeCandidate = makeImageCandidate({ ...candidate, byteCount, sha256 });
    const messages = [{
      type: 'imageBegin', origin, candidate: completeCandidate, expectedByteCount: byteCount, sha256,
    }];
    for (const chunk of chunks) messages.push({ type: 'imageChunk', origin, captureID, index: chunk.index, base64Data: chunk.base64Data });
    messages.push({ type: 'imageEnd', origin, captureID, byteCount, sha256 });
    return messages;
  }

  class ImageMessageLedger {
    constructor() {
      this.captureID = null;
      this.messages = [];
      this.position = 0;
      this.pending = null;
      this.done = false;
      this.failed = false;
    }

    begin({ captureID, messages } = {}) {
      if (this.pending || this.captureID) throw new Error('image session is busy');
      this.captureID = String(captureID || '');
      this.messages = Array.isArray(messages) ? messages.slice() : [];
      this.position = 0;
      this.pending = null;
      this.done = false;
      this.failed = false;
    }

    next() {
      if (this.done || this.failed || this.pending || this.position >= this.messages.length) return null;
      this.pending = this.messages[this.position];
      return { index: this.position, message: this.pending };
    }

    receive(response) {
      if (!response || response.captureID !== this.captureID || !this.pending) return false;
      const type = String(response.type || '');
      const isAck = type === 'ack' || type === 'presented' || type === 'animate' || type === 'saved'
        || type === 'cancelled' || type === 'failed' || /Ack$/.test(type);
      if (!isAck) return false;
      const terminal = type === 'saved' || type === 'cancelled' || type === 'failed';
      this.pending = null;
      this.position += 1;
      if (terminal) {
        this.done = true;
      } else if (this.position >= this.messages.length) {
        this.done = true;
      }
      if (type === 'failed' || type === 'cancelled') this.failed = true;
      return true;
    }

    cancel() {
      this.failed = true;
      this.done = true;
      this.pending = null;
    }
  }

  class DragSessionState {
    constructor(captureID) {
      this.captureID = String(captureID || '');
      this.phase = 'idle';
      this.lastPoint = null;
      this.insidePet = false;
      this.mouthScreenPoint = null;
    }

    start() {
      if (this.phase !== 'idle') return false;
      this.phase = 'active';
      return true;
    }

    preview(point) {
      if (this.phase !== 'active') return null;
      this.lastPoint = point && { x: finiteNumber(point.x), y: finiteNumber(point.y) };
      return this.lastPoint;
    }

    feedback(response = {}) {
      if (this.phase !== 'active' && this.phase !== 'dropped') return null;
      this.insidePet = Boolean(response.insidePet);
      if (response.mouthScreenPoint) this.mouthScreenPoint = response.mouthScreenPoint;
      return { insidePet: this.insidePet, mouthScreenPoint: this.mouthScreenPoint };
    }

    drop() {
      if (this.phase !== 'active') return false;
      this.phase = 'dropped';
      return true;
    }

    end() {
      if (this.phase === 'active') {
        this.phase = 'cancelled';
        return 'cancel';
      }
      if (this.phase === 'dropped') {
        this.phase = 'complete';
        return false;
      }
      return false;
    }
  }

  function shouldReduceMotion(matchMediaOrValue) {
    if (typeof matchMediaOrValue === 'function') return Boolean(matchMediaOrValue());
    if (typeof matchMediaOrValue === 'boolean') return matchMediaOrValue;
    try {
      return Boolean(global.matchMedia && global.matchMedia('(prefers-reduced-motion: reduce)').matches);
    } catch {
      return false;
    }
  }

  const api = {
    MAX_IMAGE_BYTES,
    IMAGE_CHUNK_BYTES,
    IMAGE_FRAME_MAX_BYTES,
    parseSrcset,
    selectSrcsetCandidate,
    selectImageURL,
    classifyImageSource,
    parseCSSBackgroundImages,
    cropRectForVisibleElement,
    resolveImageDescriptor,
    selectDOMImageMetadata,
    acquireImageBytes,
    sha256Hex,
    encodeBase64,
    decodeBase64,
    imageChunks,
    makeImageCandidate,
    buildImageMessages,
    ImageMessageLedger,
    DragSessionState,
    shouldReduceMotion,
    sanitizeResourceURL,
    responseBytes,
    toUint8Array,
  };
  global.PromptStudioImageCapture = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
}(typeof globalThis !== 'undefined' ? globalThis : this));
