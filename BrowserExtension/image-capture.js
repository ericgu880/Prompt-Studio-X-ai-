/*
 * Pure image-capture helpers shared by the MV3 content/background scripts and Node tests.
 * The module deliberately has no Chrome dependency.  Browser orchestration supplies the
 * fetch/screenshot seams so that a user action is the only point at which bytes are read.
 */
(function exposeImageCapture(global) {
  const MAX_IMAGE_BYTES = 50 * 1024 * 1024;
  const IMAGE_CHUNK_BYTES = 512 * 1024;
  const IMAGE_FRAME_MAX_BYTES = 1024 * 1024;
  const FINAL_HIT_TIMEOUT_MS = 800;
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
    const source = String(srcset || '').trim();
    const candidates = [];
    // Commas in data URL payloads are not candidate separators.  A payload comma is followed
    // by its encoded/base64 bytes, while a normal candidate separator is followed by whitespace
    // and the next URL.  Descriptor parsing below still validates the final token.
    const parts = [];
    let start = 0;
    let depth = 0;
    let quote = '';
    const startsDataURL = () => /^\s*data:/i.test(source.slice(start));
    for (let index = 0; index < source.length; index += 1) {
      const character = source[index];
      if (quote) {
        if (character === quote && source[index - 1] !== '\\') quote = '';
        continue;
      }
      if (character === '"' || character === "'") {
        quote = character;
        continue;
      }
      if (character === '(') { depth += 1; continue; }
      if (character === ')') { if (depth > 0) depth -= 1; continue; }
      if (character !== ',' || depth !== 0) continue;
      if (startsDataURL()) {
        const before = source.slice(start, index);
        const after = source.slice(index + 1).trimStart();
        const descriptorBefore = /\s+\d+(?:\.\d+)?[wx]\s*$/i.test(before);
        const nextURL = /^(?:https?:|blob:|data:|\/|\.\.?\/|[a-z0-9_-]+\.[a-z]{2,}(?:[?#]|\s|$))/i.test(after);
        if (!descriptorBefore && !nextURL) continue;
      }
      parts.push(source.slice(start, index).trim());
      start = index + 1;
    }
    parts.push(source.slice(start).trim());
    for (const part of parts.filter(Boolean)) {
      const tokens = part.trim().split(/\s+/);
      if (!tokens.length) continue;
      let descriptor = '';
      const last = tokens[tokens.length - 1].toLowerCase();
      if (/^(?:\d+(?:\.\d+)?[wx])$/.test(last)) {
        descriptor = tokens.pop();
      } else if (tokens.length > 1) {
        // Invalid descriptors are rejected rather than merging this candidate with a later URL.
        continue;
      }
      const url = tokens.join(' ');
      if (!url) continue;
      const widthMatch = /^(\d+)w$/i.exec(descriptor);
      const densityMatch = /^(\d+(?:\.\d+)?)x$/i.exec(descriptor);
      if (!descriptor) {
        candidates.push({ url, width: null, density: 1, descriptor: '' });
      } else if (widthMatch && Number(widthMatch[1]) > 0) {
        candidates.push({ url, width: Number(widthMatch[1]), density: null, descriptor: descriptor.toLowerCase() });
      } else if (densityMatch && Number(densityMatch[1]) > 0) {
        candidates.push({ url, width: null, density: Number(densityMatch[1]), descriptor: descriptor.toLowerCase() });
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

  function imageCandidateArea(element) {
    if (!element || typeof element.getBoundingClientRect !== 'function') return 0;
    const rect = element.getBoundingClientRect();
    const width = Math.max(0, finiteNumber(rect && rect.width, finiteNumber(rect && rect.right) - finiteNumber(rect && rect.left)));
    const height = Math.max(0, finiteNumber(rect && rect.height, finiteNumber(rect && rect.bottom) - finiteNumber(rect && rect.top)));
    return width * height;
  }

  function imageContainsPoint(element, point = {}) {
    if (!element || typeof element.getBoundingClientRect !== 'function') return false;
    const rect = element.getBoundingClientRect();
    const x = Number(point.x);
    const y = Number(point.y);
    return Number.isFinite(x) && Number.isFinite(y)
      && x >= finiteNumber(rect && rect.left)
      && x <= finiteNumber(rect && rect.right)
      && y >= finiteNumber(rect && rect.top)
      && y <= finiteNumber(rect && rect.bottom);
  }

  function directImageElement(element) {
    if (!element) return null;
    const tagName = String(element.tagName || element.nodeName || '').toLowerCase();
    if (tagName === 'img' || tagName === 'canvas' || tagName === 'svg') return element;
    if (tagName === 'picture' && typeof element.querySelector === 'function') {
      return element.querySelector('img, canvas, svg');
    }
    return null;
  }

  function imageElementsInside(element) {
    const direct = directImageElement(element);
    if (direct) return [direct];
    if (!element || typeof element.querySelectorAll !== 'function') return [];
    return Array.from(element.querySelectorAll('img, canvas, svg'));
  }

  // Sites such as Pinterest place a full-card link/button above the actual <img>. Native
  // dragstart therefore targets the overlay instead of the image. Resolve the largest image
  // inside that interactive card and make the hit card the temporary native drag root.
  function resolveImageDragHit(target, elementsAtPoint = [], point = {}) {
    let start = target;
    if (start && start.nodeType === 3) start = start.parentElement;
    if (!start) return null;
    const directContainer = typeof start.closest === 'function'
      ? start.closest('img, picture, canvas, svg') : null;
    const direct = directImageElement(directContainer || start);
    if (direct) return { imageElement: direct, dragRoot: direct };

    const layers = [start, ...(Array.isArray(elementsAtPoint) ? elementsAtPoint : [])];
    const visited = new Set();
    for (const layer of layers) {
      if (!layer || visited.has(layer)) continue;
      visited.add(layer);
      let root = null;
      if (typeof layer.closest === 'function') {
        root = layer.closest('a, button, [role="button"], [data-test-id*="pin" i]');
      }
      root = root || layer;
      const candidates = imageElementsInside(root)
        .filter((candidate) => imageCandidateArea(candidate) > 256 && imageContainsPoint(candidate, point))
        .sort((left, right) => imageCandidateArea(right) - imageCandidateArea(left));
      if (candidates.length) return { imageElement: candidates[0], dragRoot: root };
    }
    return null;
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

  class FrameByteStore {
    constructor({ chunkBytes = IMAGE_CHUNK_BYTES, ttlMs = 300_000, now = Date.now } = {}) {
      this.chunkBytes = Math.max(1, Math.floor(Number(chunkBytes) || IMAGE_CHUNK_BYTES));
      this.ttlMs = Math.max(1, Math.floor(Number(ttlMs) || 300_000));
      this.now = typeof now === 'function' ? now : () => Date.now();
      this.entries = new Map();
    }

    start(bytes, { storeID, mimeType = null, now = this.now() } = {}) {
      const normalized = assertImageSize(bytes);
      this.prune(now);
      if (this.entries.size) throw new Error('image store is busy');
      const id = String(storeID || `store-${Date.now()}-${Math.random().toString(36).slice(2)}`);
      this.entries.set(id, { bytes: normalized, mimeType, createdAt: now, expiresAt: now + this.ttlMs });
      return { storeID: id, byteCount: normalized.byteLength, mimeType };
    }

    read(storeID, index, now = this.now()) {
      const entry = this.entries.get(String(storeID || ''));
      if (!entry || now >= entry.expiresAt) {
        if (entry) this.entries.delete(String(storeID));
        return null;
      }
      const chunkIndex = Number(index);
      if (!Number.isInteger(chunkIndex) || chunkIndex < 0) return null;
      const start = chunkIndex * this.chunkBytes;
      if (start >= entry.bytes.byteLength) return null;
      const raw = entry.bytes.subarray(start, Math.min(entry.bytes.byteLength, start + this.chunkBytes));
      const base64Data = encodeBase64(raw);
      if (base64Data.length >= IMAGE_FRAME_MAX_BYTES) throw new Error('image chunk frame exceeds 1 MiB');
      return { storeID: String(storeID), index: chunkIndex, byteCount: raw.byteLength, base64Data, mimeType: entry.mimeType };
    }

    release(storeID) {
      return this.entries.delete(String(storeID || ''));
    }

    prune(now = this.now()) {
      for (const [id, entry] of this.entries) if (now >= entry.expiresAt) this.entries.delete(id);
    }
  }

  function accumulateFrameCoordinates(rect, offsets = []) {
    const result = {
      left: finiteNumber(rect && rect.left),
      top: finiteNumber(rect && rect.top),
      right: finiteNumber(rect && rect.right),
      bottom: finiteNumber(rect && rect.bottom),
    };
    for (const offset of offsets || []) {
      result.left += finiteNumber(offset && offset.left);
      result.top += finiteNumber(offset && offset.top);
      result.right += finiteNumber(offset && offset.left);
      result.bottom += finiteNumber(offset && offset.top);
    }
    return result;
  }

  function cropRectFromScreenRect(rect, metrics = {}, devicePixelRatio = 1, screenshotSize = null) {
    const dpr = positiveNumber(devicePixelRatio, 1);
    const screenX = finiteNumber(metrics.screenX);
    const screenY = finiteNumber(metrics.screenY);
    const chromeHeight = Math.max(0, finiteNumber(metrics.browserChromeHeight));
    const viewportWidth = positiveNumber(metrics.viewportWidth, 0);
    const viewportHeight = positiveNumber(metrics.viewportHeight, 0);
    const pixelWidth = Math.max(0, finiteNumber(screenshotSize && screenshotSize.width));
    const pixelHeight = Math.max(0, finiteNumber(screenshotSize && screenshotSize.height));
    const scaleX = pixelWidth && viewportWidth ? pixelWidth / viewportWidth : dpr;
    const scaleY = pixelHeight && viewportHeight ? pixelHeight / viewportHeight : dpr;
    const left = finiteNumber(rect && rect.left) - screenX;
    const top = finiteNumber(rect && rect.top) - screenY - chromeHeight;
    const right = finiteNumber(rect && rect.right) - screenX;
    const bottom = finiteNumber(rect && rect.bottom) - screenY - chromeHeight;
    const rawLeft = Math.round(left * scaleX);
    const rawTop = Math.round(top * scaleY);
    const rawRight = Math.round(right * scaleX);
    const rawBottom = Math.round(bottom * scaleY);
    if (!pixelWidth || !pixelHeight) {
      return {
        left: rawLeft,
        top: rawTop,
        width: Math.max(0, rawRight - rawLeft),
        height: Math.max(0, rawBottom - rawTop),
      };
    }
    const maxWidth = pixelWidth;
    const maxHeight = pixelHeight;
    const clippedLeft = Math.max(0, Math.min(maxWidth, rawLeft));
    const clippedTop = Math.max(0, Math.min(maxHeight, rawTop));
    const clippedRight = Math.max(clippedLeft, Math.min(maxWidth, rawRight));
    const clippedBottom = Math.max(clippedTop, Math.min(maxHeight, rawBottom));
    return {
      left: clippedLeft,
      top: clippedTop,
      width: Math.max(0, clippedRight - clippedLeft),
      height: Math.max(0, clippedBottom - clippedTop),
    };
  }

  // A pointer event carries both viewport-local and screen coordinates.  The delta is the
  // frame's screen origin, so applying it to the element rect maps nested/cross-origin frames
  // without reading frameElement or asking for privileged tab geometry.
  function screenRectFromPointerRect(rect, pointer = {}) {
    const localX = finiteNumber(pointer.clientX);
    const localY = finiteNumber(pointer.clientY);
    const screenX = finiteNumber(pointer.screenX, localX);
    const screenY = finiteNumber(pointer.screenY, localY);
    const offsetX = screenX - localX;
    const offsetY = screenY - localY;
    return {
      left: finiteNumber(rect && rect.left) + offsetX,
      top: finiteNumber(rect && rect.top) + offsetY,
      right: finiteNumber(rect && rect.right) + offsetX,
      bottom: finiteNumber(rect && rect.bottom) + offsetY,
    };
  }

  function preferredDragSourceScreenRect(pointerDownRect, dragStartRect) {
    const isUsable = (rect) => rect
      && Number.isFinite(Number(rect.left))
      && Number.isFinite(Number(rect.top))
      && Number.isFinite(Number(rect.right))
      && Number.isFinite(Number(rect.bottom))
      && Number(rect.right) > Number(rect.left)
      && Number(rect.bottom) > Number(rect.top);
    if (isUsable(pointerDownRect)) return pointerDownRect;
    return isUsable(dragStartRect) ? dragStartRect : null;
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
      const messageType = String(this.pending.type || '');
      if (type === 'saved' || type === 'cancelled' || type === 'failed') {
        this.pending = null;
        this.done = true;
        this.failed = type === 'failed' || type === 'cancelled';
        return true;
      }
      if (messageType === 'imageBegin' || messageType === 'imageChunk') {
        const expectedCode = messageType === 'imageBegin' ? 'image-begin-accepted' : 'image-chunk-accepted';
        if (type !== 'ack' || response.code !== expectedCode) return false;
        this.pending = null;
        this.position += 1;
        return true;
      }
      if (messageType !== 'imageEnd') return false;
      if (type === 'presented' || type === 'animate') return true;
      return false;
    }

    replay() {
      if (!this.captureID) return false;
      this.position = 0;
      this.pending = null;
      this.done = false;
      this.failed = false;
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
      this.previewSequence = 0;
      this.pendingPreviewSequences = new Set();
      this.nativeInsidePet = false;
      this.nativeMouthScreenPoint = null;
      this.lastNativeSequence = 0;
      this.finalPending = null;
    }

    start() {
      if (this.phase !== 'idle') return false;
      this.phase = 'active';
      return true;
    }

    preview(point) {
      if (this.phase !== 'active') return null;
      this.previewSequence += 1;
      this.pendingPreviewSequences.add(this.previewSequence);
      this.lastPoint = point && { x: finiteNumber(point.x), y: finiteNumber(point.y), sequence: this.previewSequence };
      return this.lastPoint;
    }

    consumePreviewAck(response = {}) {
      if (!response || response.captureID !== this.captureID) return false;
      if (response.type !== 'imageDragPreviewAck' && response.type !== 'ack') return false;
      const sequence = Number(response.sequence);
      if (!Number.isInteger(sequence) || sequence > this.previewSequence
          || sequence <= this.lastNativeSequence || !this.pendingPreviewSequences.has(sequence)) return false;
      this.pendingPreviewSequences.delete(sequence);
      this.lastNativeSequence = sequence;
      this.nativeInsidePet = Boolean(response.insidePet);
      this.nativeMouthScreenPoint = response.mouthScreenPoint || response.mouthPoint || null;
      this.insidePet = this.nativeInsidePet;
      this.mouthScreenPoint = this.nativeMouthScreenPoint;
      return true;
    }

    requestFinalize(point, now = Date.now()) {
      if (this.phase !== 'active' || this.finalPending) return null;
      this.previewSequence += 1;
      const sequence = this.previewSequence;
      const finalPoint = point && { x: finiteNumber(point.x), y: finiteNumber(point.y) };
      this.finalPending = { sequence, point: finalPoint, expiresAt: Number(now) + FINAL_HIT_TIMEOUT_MS };
      this.pendingPreviewSequences.add(sequence);
      this.lastPoint = finalPoint && { ...finalPoint, sequence };
      return { sequence, point: finalPoint, expiresAt: this.finalPending.expiresAt };
    }

    consumeFinalAck(response = {}, now = Date.now()) {
      if (!this.finalPending || !response || response.captureID !== this.captureID) return null;
      const sequence = Number(response.sequence);
      if (sequence !== this.finalPending.sequence) return null;
      if (Number(now) >= this.finalPending.expiresAt) return this.finalizeTimeout(now);
      this.pendingPreviewSequences.delete(sequence);
      this.lastNativeSequence = sequence;
      this.nativeInsidePet = Boolean(response.insidePet);
      this.nativeMouthScreenPoint = response.mouthScreenPoint || response.mouthPoint || null;
      this.insidePet = this.nativeInsidePet;
      this.mouthScreenPoint = this.nativeMouthScreenPoint;
      this.finalPending = null;
      if (this.nativeInsidePet) {
        this.phase = 'dropped';
        return 'drop';
      }
      this.phase = 'cancelled';
      return 'cancel';
    }

    finalizeTimeout(now = Date.now()) {
      if (!this.finalPending || Number(now) < this.finalPending.expiresAt) return null;
      this.pendingPreviewSequences.delete(this.finalPending.sequence);
      this.finalPending = null;
      this.phase = 'cancelled';
      return 'cancel';
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

    dragEnd() {
      if (this.phase !== 'active') return false;
      if (this.nativeInsidePet) {
        this.phase = 'dropped';
        return 'drop';
      }
      this.phase = 'cancelled';
      return 'cancel';
    }
  }

  class ImageReplayController {
    constructor({ now = Date.now, maxAttempts = 3, ttlMs = 300_000 } = {}) {
      this.now = typeof now === 'function' ? now : () => Date.now();
      this.maxAttempts = Math.max(1, Math.floor(Number(maxAttempts) || 3));
      this.ttlMs = Math.max(1, Math.floor(Number(ttlMs) || 300_000));
      this.captureID = null;
      this.messages = [];
      this.createdAt = 0;
      this.attempts = 0;
    }

    begin(captureID, messages, now = this.now()) {
      this.captureID = String(captureID || '');
      this.messages = Array.isArray(messages) ? messages.slice() : [];
      this.createdAt = now;
      this.attempts = 0;
    }

    replay(now = this.now()) {
      if (!this.captureID || now - this.createdAt >= this.ttlMs || this.attempts >= this.maxAttempts) return null;
      this.attempts += 1;
      return this.messages.slice();
    }

    clear() {
      this.captureID = null;
      this.messages = [];
      this.createdAt = 0;
      this.attempts = 0;
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

  function dragEndScreenPoint(event, fallbackPoint) {
    const screenX = Number(event && event.screenX);
    const screenY = Number(event && event.screenY);
    if (Number.isFinite(screenX) && Number.isFinite(screenY)) {
      return { x: screenX, y: screenY };
    }
    return fallbackPoint || null;
  }

  function makeDragPreviewMessage({ captureID, screenPoint, sourceScreenRect, sequence } = {}) {
    return {
      type: 'previewImageDrag',
      captureID: String(captureID || ''),
      screenPoint: screenPoint || null,
      sourceScreenRect: sourceScreenRect || null,
      sequence: Number(sequence),
    };
  }

  const api = {
    MAX_IMAGE_BYTES,
    IMAGE_CHUNK_BYTES,
    IMAGE_FRAME_MAX_BYTES,
    FINAL_HIT_TIMEOUT_MS,
    parseSrcset,
    selectSrcsetCandidate,
    selectImageURL,
    classifyImageSource,
    parseCSSBackgroundImages,
    resolveImageDragHit,
    cropRectForVisibleElement,
    resolveImageDescriptor,
    selectDOMImageMetadata,
    acquireImageBytes,
    sha256Hex,
    encodeBase64,
    decodeBase64,
    imageChunks,
    assertImageSize,
    FrameByteStore,
    accumulateFrameCoordinates,
    cropRectFromScreenRect,
    screenRectFromPointerRect,
    preferredDragSourceScreenRect,
    makeImageCandidate,
    buildImageMessages,
    ImageMessageLedger,
    DragSessionState,
    ImageReplayController,
    dragEndScreenPoint,
    makeDragPreviewMessage,
    shouldReduceMotion,
    sanitizeResourceURL,
    responseBytes,
    toUint8Array,
  };
  global.PromptStudioImageCapture = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
}(typeof globalThis !== 'undefined' ? globalThis : this));
