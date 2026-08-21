# PromptStudio Testing Plan

This document defines the current test gates for PromptStudio. It covers the macOS app, `PromptStudioCore`, CLI, MCP, local data persistence, manual UI checks, and release readiness.

For the full Chinese release-candidate manual QA cases, use
`docs/PromptStudio_Release_QA_Test_Cases.md`.

## Automated Gates

Run these before merging code:

```sh
source Scripts/swift_toolchain.sh
SWIFT_EXEC="$(find_compatible_swift_tool swift)"
"$SWIFT_EXEC" build
"$SWIFT_EXEC" build -c release --product PromptStudio
"$SWIFT_EXEC" test
"$SWIFT_EXEC" run PromptStudioCoreUnitTests
"$SWIFT_EXEC" run PromptStudioSmokeTests
bash Scripts/test_swift_toolchain.sh
bash Scripts/test_license_keychain.sh
bash Scripts/test_codesign_policy.sh
bash Scripts/test_release_ui_copy.sh
bash Scripts/test_batch_media_import.sh
bash Scripts/test_prompt_smart_paste.sh
```

- Debug build must compile `PromptStudio`, `promptstudioctl`, `PromptStudioMCP`, and `PromptStudioSmokeTests`; the explicit Release product build protects `#if DEBUG` production behavior.
- `swift test` must keep the SwiftPM test target buildable. The current Command Line Tools install does not expose XCTest/Testing.
- `swift run PromptStudioCoreUnitTests` owns focused `PromptStudioCore` unit coverage.
- `swift run PromptStudioSmokeTests` owns executable end-to-end coverage across Core, CLI, and MCP.

## Core Unit Tests

Target: `Sources/PromptStudioCoreUnitTests`

Coverage:

- `AssetKind` inference.
- `PromptImportParser` text, tag, negative prompt, and parameter parsing.
- `PromptFiltering` query, model, tag, folder, recent sorting, and trash behavior.
- `PromptRepository` round trips for items, versions, tags, folders, thumbnails, last-used dates, trash/restore, and seed asset repair.
- `MediaImportService` nested scanning, bounded concurrency, stable ordering, batch rollback, cancellation cleanup, and 100-file persistence.
- `PromptStudioAutomationService` prompt creation, updates, text imports, image metadata imports, and validation.

Core unit tests should not spawn app processes or depend on the default user library. Use temporary library directories.

`Tests/PromptStudioCoreTests` remains as a lightweight build target until XCTest/Swift Testing is available in the local toolchain.

## Smoke / E2E Tests

Target: `Sources/PromptStudioSmokeTests`

Coverage:

- Temporary library lifecycle.
- CLI lifecycle:
  - `create-folder`
  - `create-prompt`
  - `update-prompt`
  - `add-tags`
  - `favorite --on`
  - `delete`
  - `list --trash`
  - `restore`
  - `get`
- CLI error behavior:
  - missing required parameter exits non-zero
  - missing import file exits non-zero
- MCP lifecycle:
  - `initialize`
  - `tools/list`
  - `tools/call`
  - successful write persists to the repository
  - missing required arguments return JSON-RPC errors

When Core, CLI, MCP, or repository behavior changes, run the smoke target.

## CLI Acceptance

Use a temporary library for manual verification:

```sh
LIB="$(mktemp -d)"
swift run promptstudioctl --library "$LIB" create-folder --name "QA"
swift run promptstudioctl --library "$LIB" create-prompt --title "QA Prompt" --prompt "cinematic product photo" --tags "产品,写实"
swift run promptstudioctl --library "$LIB" list --query "product"
```

Acceptance criteria:

- All successful data commands print valid JSON.
- Writes are persisted in the selected `--library`.
- Missing required arguments return a non-zero exit code.
- Bad import paths return a non-zero exit code.
- No command uploads files, prompts, paths, or keys.

## MCP Acceptance

Use stdio JSON-RPC frames against `PromptStudioMCP`.

Required tool coverage:

- `list_items`
- `get_item`
- `create_prompt`
- `update_prompt`
- `import_files`
- `list_folders`
- `move_item`
- `add_tags`
- `favorite_item`
- `trash_item`
- `restore_item`

Acceptance criteria:

- `initialize` returns server info and tool capabilities.
- `tools/list` exposes all required tools.
- `tools/call` returns MCP `content` with JSON text for successful calls.
- Missing arguments return JSON-RPC errors.
- Write tools persist to the same local library visible to CLI and the app.

## Manual UI Smoke Checklist

Use a temporary library for destructive UI checks. Do not run create, edit,
delete, restore, import, or bulk tests against a real user library.

```sh
APP_PATH="$(
  SIGN_IDENTITY='Developer ID Application: Team Name (ABCDE12345)' \
  EXPECTED_TEAM_ID='ABCDE12345' \
  Scripts/build_app.sh debug
)"
LIB="$(mktemp -d /tmp/promptstudio-ui-qa.XXXXXX)"
open "$APP_PATH" --args --library "$LIB"
```

The UI run can be marked PASS only when the app is confirmed to use the test
library, for example by Settings showing the temporary path or by filesystem
evidence under `$LIB`.

### Startup And Window

- First launch creates or reads the selected local library.
- Main window shows the three-column layout.
- Resize, full screen, minimize, and restore do not break layout.
- Dark UI, glass sidebar, inspector, and content area have no obvious visual regressions.

### Browsing

- Seed assets display.
- Image, video, Markdown, JSON, plain text, and unknown file placeholders are reasonable.
- Search works by title, prompt body, tags, model, and folder.
- Model, folder, tag, favorite, recent, and trash filters can be combined.

### Import

- Drag image, video, Markdown, JSON, and txt files into the app.
- Import a folder with mixed files.
- Imported items preserve title, format, file size, dimensions, aspect ratio where available, and parsed prompt metadata.
- Imported files remain available after deleting the original source file.

### Editing And Versions

- Create a new prompt.
- Edit prompt text and save as a new version.
- Copy prompt to clipboard.
- View, copy, and restore historical versions.
- Add tags and filter by them.

### Folders And Trash

- Create, rename, and delete folders.
- Move items between folders.
- Move item to trash.
- Restore item from trash.
- Empty trash and verify item count changes.

### Preview And Export

- Space opens and closes preview.
- Image, video, and text previews render.
- Export Prompt Markdown.
- Export image PNG/JPG.
- Missing source files show an understandable error and do not crash.

## Release Matrix

### System

- macOS 15, Apple Silicon: required.
- Intel or lower macOS: test only if support is added.

### Library States

- Empty library.
- Seed-only library.
- 100 items.
- 1000 items.
- Missing source files.
- Old or migrated SQLite schema.
- Mixed assets: image, video, Markdown, JSON, txt, PDF.

### Performance Baselines

- App launch to interactive.
- Search with 1000 items. Automated Core smoke:
  `testFilteringPerformanceWith1000Items` requires combined query, tag, folder,
  model, favorite, and prompt-present filters to finish under 500 ms.
- SQLite repository 1000-item save/load. Automated Core smoke:
  `testRepositoryBulkSaveLoadPerformanceWith1000Items` requires saving and
  reloading 1000 prompt records with versions, tags, folders, model metadata,
  and prompt parameters to finish under 5 s.
- Import 100 mixed files.
- Thumbnail generation while UI remains usable.
- Memory does not grow without bound during browse/import/preview.

Launch, scroll responsiveness, thumbnail UI responsiveness, import UI latency,
and memory growth remain manual release checks or `/macos-qa` checks because
they depend on the real macOS app process and UI rendering.

### Privacy

- App, CLI, and MCP do not make network requests by default.
- App, CLI, and MCP only read and write the selected local library.
- API keys are not printed.
- Error logs do not expose full sensitive prompts unless the user explicitly exports or copies them.

### Release Packaging

Local release QA requires a signed app bundle that passes strict verification:

```sh
APP_PATH="$(
  LICENSE_SIGNING_KEY_ID=prod-2026-01 \
  LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL='...' \
  SIGN_IDENTITY='Developer ID Application: Team Name (ABCDE12345)' \
  EXPECTED_TEAM_ID='ABCDE12345' \
  Scripts/build_app.sh release
)"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH" 2>&1
codesign -d -r- "$APP_PATH" 2>&1
```

To preserve the debug build's development License behavior while giving Keychain
a stable application identity, package debug with the same Developer ID identity:

```sh
SIGN_IDENTITY='Developer ID Application: Team Name (ABCDE12345)' \
EXPECTED_TEAM_ID='ABCDE12345' \
Scripts/build_app.sh debug
```

`Scripts/build_app.sh` defaults to release and fails closed when signing inputs are
missing. Ad-hoc signing is permitted only for `Scripts/build_app.sh debug`. Any
Developer ID build requires hardened runtime, a secure timestamp, an explicitly
expected Team ID, and a stable designated requirement pinned to that Team ID.
Release additionally requires a valid 32-byte Ed25519 License public key. Run
`bash Scripts/test_codesign_policy.sh` to verify the local release gate and
`bash Scripts/test_license_keychain.sh` for the License Keychain regression suite.
Optionally provide `ENTITLEMENTS_PATH`; release packaging rejects
`com.apple.security.get-task-allow=true`.

The app target currently uses Swift 5 language mode with a Swift 6.2-or-newer
toolchain. This keeps the existing AppKit image-loading code buildable until its
`NSImage` concurrency boundaries are migrated to Swift 6.

For License Keychain recovery, launch must never open an authentication dialog by
itself. A denied Pro action must open **License → 钥匙串访问** and present two
explicit choices:

- **保留并迁移** may require separate macOS approval for multiple historical
  records. It preserves every legacy item and never deletes an older Vault.
- **创建新身份** must not read, update, or delete the legacy service or any
  `v2...v16` Vault. It writes and verifies one randomly named Vault, preserves the
  local library, does not copy the prior activation or Trial, does not start a new
  Trial, and routes directly to online activation.

Confirm the B dialog includes the full no-delete, no-library-impact,
reactivation, and no-new-Trial warning. After B, quit and relaunch: the app must
read only the active random Vault and remain in reactivation-required state until
a valid activation succeeds. Failed or cancelled activation must not remove the
recovery marker.

Ad-hoc Debug signatures are intentionally unstable: a rebuild changes the code
requirement and cannot prove cross-build zero-prompt behavior. Final Keychain
acceptance therefore requires two separately built bundles signed with the same
Developer ID Team ID. Recover with the first bundle, launch the second bundle,
and verify that neither startup nor a Pro action presents a Keychain password
dialog. In both runs, confirm the selected library path and resource counts are
unchanged.
Run notarization when Apple credentials are available. If credentials are not
available, mark notarization as `ENVIRONMENT/SKIPPED`; do not mark the product
failed solely because credentials are missing.

## Execution Rhythm

- Code-only change: run `swift build` and `swift test`.
- Core change: also run `swift run PromptStudioCoreUnitTests`.
- Core/CLI/MCP change: also run `swift run PromptStudioSmokeTests`.
- UI change: run `swift build` and the manual UI smoke checklist; run smoke tests if the UI change writes data.
- Release candidate: run all automated gates, full manual UI smoke against a temporary library, CLI/MCP manual acceptance, packaging/signing/notarization, and first-launch verification.
