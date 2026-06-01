# PromptStudio Testing Plan

This document defines the current test gates for PromptStudio. It covers the macOS app, `PromptStudioCore`, CLI, MCP, local data persistence, manual UI checks, and release readiness.

## Automated Gates

Run these before merging code:

```sh
swift build
swift test
swift run PromptStudioCoreUnitTests
swift run PromptStudioSmokeTests
```

- `swift build` must compile `PromptStudio`, `promptstudioctl`, `PromptStudioMCP`, and `PromptStudioSmokeTests`.
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

### Startup And Window

- First launch creates or reads the default local library.
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
- Search with 1000 items.
- Import 100 mixed files.
- Thumbnail generation while UI remains usable.
- Memory does not grow without bound during browse/import/preview.

### Privacy

- App, CLI, and MCP do not make network requests by default.
- CLI/MCP only read and write the selected local library.
- API keys are not printed.
- Error logs do not expose full sensitive prompts unless the user explicitly exports or copies them.

## Execution Rhythm

- Code-only change: run `swift build` and `swift test`.
- Core change: also run `swift run PromptStudioCoreUnitTests`.
- Core/CLI/MCP change: also run `swift run PromptStudioSmokeTests`.
- UI change: run `swift build` and the manual UI smoke checklist; run smoke tests if the UI change writes data.
- Release candidate: run all automated gates, full manual UI smoke, CLI/MCP manual acceptance, packaging/signing/notarization, and first-launch verification.
