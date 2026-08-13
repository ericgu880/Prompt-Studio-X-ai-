# Web Image Capture and Pet Drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add authenticated/fallback web image capture and native desktop-pet right-click/drag-drop ingestion without duplicating saved items.

**Architecture:** The extension resolves page image metadata and streams bytes in bounded chunks through the existing Native Messaging host. The host owns secure staging and forwards tokenized candidates to the app socket. PromptStudio validates and imports the staged image through the existing repository, while the pet coordinator owns confirmation and drag UI state.

**Tech Stack:** Swift 6.2, AppKit/SwiftUI, SQLite, Foundation/ImageIO/CryptoKit, Manifest V3 JavaScript, Node test runner.

## Global Constraints

- macOS only; Chrome, Edge, and Arc; no Safari or Windows.
- No `debugger`, Cookie, history, or extra `tabs` permission; no remote request from the Native Host.
- Native Messaging frames remain <= 1MiB; image chunks contain 512KiB raw bytes before Base64 encoding.
- Staging directory mode `0700`, staging file mode `0600`, 50MB file limit, 100MP raster limit, 120-second transfer timeout, 10-minute staging TTL.
- Preserve original animated image bytes; screenshot fallback is PNG and tagged `截图采集`.
- One active image session; contention returns `image-busy` with `retryable: true`.
- Never log image bytes or a complete resource URL; never accept a browser-provided local file path.

---

### Task 1: Core image candidate, validation, and idempotent repository import

**Files:**
- Modify: `Sources/PromptStudioCore/WebCaptureModels.swift`
- Modify: `Sources/PromptStudioCore/PromptStudioAutomationService.swift`
- Modify: `Sources/PromptStudioCore/PromptRepository.swift`
- Test: `Sources/PromptStudioCoreUnitTests/main.swift`
- Test: `Tests/PromptStudioCoreTests/PromptStudioCoreTests.swift`

**Interfaces:**
- Produces `ImageDOMSourceKind`, `ImageAcquisitionMethod`, `WebImageCaptureCandidate` and `PromptStudioAutomationService.createCapturedImage(_:stagedFileURL:) throws -> PromptItem`.
- Extends `CapturedSource` only with optional Codable fields so legacy JSON still decodes.

- [ ] Write failing tests for legacy source decoding, URL sanitization, title priority, actual format detection, 50MB and 100MP boundaries, screenshot tags, animated-byte preservation, captureID idempotency, and staging ownership/path rejection.
- [ ] Run `source Scripts/swift_toolchain.sh && swift run PromptStudioCoreUnitTests`; verify the new assertions fail because the image APIs do not exist.
- [ ] Add the public types and optional source fields. `WebImageCaptureCandidate` must carry capture ID, page metadata, sanitized resource metadata, alt/filename, source/acquisition enums, screenshot flag, MIME hint, byte count, SHA-256, pixel hints, click point, and capture time.
- [ ] Implement staging validation with `lstat`, current-UID ownership, regular-file/no-symlink checks, SHA-256, magic-byte format detection, ImageIO dimensions/frame inspection, exact limits, then use `copyAssetIntoLibrary(..., assetKind: .image)` and the existing atomic capture save path.
- [ ] Run the targeted Core suites and `git diff --check`; expect all new and existing tests to pass.
- [ ] Commit only Task 1 files with message `feat(core): import captured web images`.

### Task 2: Native Host chunk staging and streaming protocol

**Files:**
- Modify: `Sources/PromptStudioCaptureHost/CaptureHostTypes.swift`
- Modify: `Sources/PromptStudioCaptureHost/CaptureHostRuntime.swift`
- Add: `Sources/PromptStudioCaptureHost/ImageStagingStore.swift`
- Modify: `Tests/PromptStudioCaptureHostTests/CaptureHostTests.swift`

**Interfaces:**
- Consumes browser messages `imageBegin`, `imageChunk`, `imageEnd`, `imageCancel`, `imageDragPreview`, `imageDragCancel`.
- Produces app-socket messages using a random staging token and exposes no filesystem path to the browser.

- [ ] Write failing tests for begin/chunk/end, 512KiB ordering, duplicates, truncation, SHA mismatch, 50MB rejection, timeout/TTL cleanup, disconnect retry, path/token forgery, mode/owner checks, illegal origin, and `image-busy`.
- [ ] Run `source Scripts/swift_toolchain.sh && swift test --filter PromptStudioCaptureHostTests`; verify failures are caused by missing staging/protocol behavior.
- [ ] Implement a single-session actor/store that creates the secure staging directory and file, streams decoded chunks in order, hashes while writing, rejects client paths, and prunes expired files.
- [ ] Extend runtime routing so control frames get bounded acknowledgements, `imageEnd` streams the tokenized candidate to the existing app socket, and terminal app frames return to the originating browser tab.
- [ ] Run Host tests plus `swift build` and `git diff --check`; expect zero failures.
- [ ] Commit Task 2 files with message `feat(host): stage browser image captures`.

### Task 3: Extension DOM resolution, acquisition, menus, and drag sessions

**Files:**
- Modify: `BrowserExtension/manifest.json`
- Modify: `BrowserExtension/background.js`
- Modify: `BrowserExtension/background-logic.js`
- Modify: `BrowserExtension/content.js`
- Modify: `BrowserExtension/content-core.js`
- Modify: `BrowserExtension/content.css`
- Add: `BrowserExtension/image-capture.js`
- Add: `BrowserExtension/test/image-capture.test.js`
- Modify: `BrowserExtension/test/extension-policy.test.js`

**Interfaces:**
- Emits Task 2 messages and consumes `presented`, `animate`, `saved`, `cancelled`, `failed` responses.
- Resolves visible element metadata in the correct frame and captures only after explicit context-menu click or drag start.

- [ ] Write failing Node tests for currentSrc, srcset ranking, data/blob/canvas/SVG/CSS parsing, frame routing, page-context/background fetch order, screenshot crop, 512KiB chunk boundaries, drag cleanup, permissions, busy/retry behavior, and URL redaction.
- [ ] Run `node --test BrowserExtension/test/*.test.js`; verify failures are due to missing image capture functions and manifest entries.
- [ ] Add only `contextMenus` and `scripting`, set `all_frames: true`, and create the two context-sensitive Chinese menu entries.
- [ ] Implement DOM metadata resolution and byte acquisition in the ordered fallback pipeline; crop only the visible element intersection for screenshot fallback and mark it explicitly.
- [ ] Implement one drag session: prefetch on `dragstart`, send preview coordinates, detect pet hit feedback from host/app, send chunk stream on drop, and cancel on unfinished `dragend`; render a shrinking in-mouth duplicate without modifying the native drag ghost.
- [ ] Run all Node tests and existing ID/registration/packaging policy scripts; expect zero failures.
- [ ] Commit Task 3 files with message `feat(extension): capture and feed web images`.

### Task 4: App socket, pet interaction, and active-library save integration

**Files:**
- Modify: `Sources/PromptStudio/Pet/PetCaptureTypes.swift`
- Modify: `Sources/PromptStudio/Pet/PetCaptureSocketServer.swift`
- Modify: `Sources/PromptStudio/Pet/PetCoordinator.swift`
- Modify: `Sources/PromptStudio/Pet/PetPanelController.swift`
- Modify: `Sources/PromptStudio/Pet/PetView.swift`
- Modify: `Sources/PromptStudio/AppState.swift`
- Modify: `Scripts/run_pet_tests.sh`
- Modify: `Tests/PromptStudioPetTests/main.swift`

**Interfaces:**
- Consumes Task 2 tokenized candidates and calls Task 1 `createCapturedImage` against `AppState.libraryURL` at request time.
- Produces right-click confirmation outcomes and drag `ImageDropPhase` preview/terminal outcomes.

- [ ] Write failing pet executable tests for right-click confirm/cancel, drag enter/exit/drop, mouth preview scaling, hidden temporary presentation/restoration, busy, reduced motion, save failure, token rejection, and active-library switching.
- [ ] Run `Scripts/run_pet_tests.sh`; verify new tests fail because image capture states and handlers are absent.
- [ ] Add image request/outcome wire types without changing the existing text capture contract; enforce one active image session independently from text capture state.
- [ ] Add temporary image-pet presentation, confirmation thumbnail/acquisition label, native panel hit region, mouth-copy scaling, drag enter/exit/drop, and deterministic hidden-state restoration.
- [ ] Resolve the staging token only inside the App/Host trust boundary and call Task 1 using the current library URL; delete staging files after terminal success/cancel/failure.
- [ ] Run pet tests, Core tests, Host tests, `swift build`, and `git diff --check`; expect zero failures.
- [ ] Commit Task 4 files with message `feat(pet): accept browser image drops`.

### Task 5: Integrated packaging and three-browser regression harness

**Files:**
- Modify: `Scripts/build_app.sh`
- Modify: `Scripts/test_browser_host_packaging.sh`
- Modify: `BrowserExtension/README.md`
- Add: `Scripts/test_web_image_capture_protocol.sh`

**Interfaces:**
- Packages all Task 1–4 code without changing the production extension-origin policy.

- [ ] Write failing packaging/protocol tests that assert new extension assets are bundled, staging cleanup runs, message schemas align across JS/Host/App, and logs omit full URLs and bytes.
- [ ] Run the new script and existing packaging checks; verify expected failures before production edits.
- [ ] Update packaging and operator instructions for Chrome, Edge, and Arc; document explicit production extension ID requirements and manual browser fixture matrix.
- [ ] Run Node tests, Swift Core/Host/pet suites, full `swift build`, debug app packaging/sign verification, all policy scripts, and a 100-capture protocol soak with no duplicates or staging residue.
- [ ] Commit Task 5 files with message `test(capture): verify web image pipeline`.

