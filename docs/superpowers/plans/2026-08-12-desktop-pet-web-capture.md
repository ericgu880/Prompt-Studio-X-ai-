# PromptStudio Desktop Pet and Web Capture Implementation Plan

> **For agentic workers:** Use test-driven development. Work only in the assigned worktree and files, commit the result, and report exact verification commands.

**Goal:** Deliver the approved macOS desktop pet and local Chromium text-capture MVP.

**Architecture:** PromptStudioCore owns capture validation, persistence, and idempotency. The native app owns the non-activating pet panel, settings, and Unix-socket capture coordinator. A Manifest V3 extension talks to a bundled Swift native-messaging host and owns selection/page animation.

**Tech stack:** Swift 6.2 package targeting macOS 15, SwiftUI/AppKit, SQLite, Unix domain sockets, Manifest V3 JavaScript/CSS, Node built-in tests.

## Global constraints

- All capture data stays local; no extension network requests.
- The feature is free, while the dedicated capture API cannot become a general replacement for Pro prompt creation.
- Selection limit is 50,000 characters; title limit is 40 characters.
- Host origins are exact extension IDs with no wildcard.
- Existing user changes and unrelated files must not be reverted or reformatted.

### Task 1: Core capture model and persistence

- Add capture protocol/source types, PromptItem fields, SQLite migration and unique index.
- Add the capture inbox, unspecified text model, title normalization, validation, and idempotent `createCapturedPrompt` service.
- Start with failing core tests for migration, serialization, empty/oversized input, title generation, folder/model/tags, and duplicate capture IDs.
- Verify with `swift test` and `swift run PromptStudioCoreUnitTests`.

### Task 2: Pet window, app coordination, and settings

- Add focused Pet files for state, view, non-activating NSPanel controller, coordinator, capture socket server, preferences, and host registration UI/service.
- Integrate lifecycle with PromptStudioApp/AppState, menu-bar restore, right-click controls, hidden-mode notification, reduced motion, and settings.
- Add tests for pure state transitions, preference defaults, coordinate mapping, host manifest generation, and capture request routing before implementation.
- Verify Swift build and focused tests.

### Task 3: Browser extension and native host

- Add Manifest V3 extension files, selection overlay, timeout/scroll/password/restricted-page handling, Native Messaging reconnect, and text-flight animation.
- Add `PromptStudioCaptureHost`, length-framed JSON protocol, origin validation, socket forwarding, cold app launch, and browser manifest registration helpers/packaging.
- Start with Node protocol/selection/coordinate tests and Swift host framing/origin tests.
- Verify Node tests, Swift build, and packaging policy tests.

### Task 4: Integrate and validate

- Merge tasks into the integration worktree, resolve interface differences without weakening constraints, and add any missing cross-subsystem tests.
- Run full Swift tests, core unit/smoke tests, Node tests, build, release scripts that are safe locally, and diff review.
- Document manual Chrome/Edge/Arc installation and E2E checks, including cold start, hidden mode, multiple displays, and 100 captures.

