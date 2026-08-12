# On-Demand Smart Paste Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the persistent post-fill smart-paste bar with an empty-draft entry, a four-second undo notice, and a header overflow menu.

**Architecture:** Keep the existing parser, prefill token, interpretation, and draft snapshot. Change only the composer presentation and transient notice state; existing smart-paste actions remain backed by the same request, undo, clear, and detail functions.

**Tech Stack:** SwiftUI, AppKit clipboard bridge, Swift shell regression tests, Swift Package Manager.

## Global Constraints

- The empty create composer shows `从剪贴板智能填充 ⌘V`.
- Successful fill removes the entry without leaving layout space.
- The success notice lasts four seconds and offers Undo.
- Persistent secondary actions live in the create-page header overflow menu.
- Editing mode continues to reject smart paste.
- No clipboard history, database migration, server, or API is introduced.

---

### Task 1: Lock the on-demand presentation contract

**Files:**
- Modify: `Scripts/test_prompt_smart_paste.sh`
- Modify: `Scripts/test_prompt_composer_simplification.sh`

**Interfaces:**
- Consumes: `PromptComposerOverlay` source text.
- Produces: regression checks for the empty-only entry, transient notice, header menu, and removed persistent filled bar.

- [ ] Add failing checks for `shouldShowSmartPasteEntry`, `showSmartPasteSuccessNotice`, a four-second dismissal task, and header-menu actions.
- [ ] Run `bash Scripts/test_prompt_smart_paste.sh` and confirm it fails because the new presentation state does not exist.
- [ ] Add a negative check rejecting the old `已智能填充 ·` persistent copy.

### Task 2: Implement the on-demand entry and transient notice

**Files:**
- Modify: `Sources/PromptStudio/Views/Overlays.swift`

**Interfaces:**
- Consumes: `requestSmartPaste()`, `applySmartPaste(_:)`, `undoSmartPaste()`, `clearSmartPaste()`, `showSmartPasteDetails`.
- Produces: `shouldShowSmartPasteEntry: Bool`, `showSmartPasteSuccessNotice: Bool`, and `smartPasteNoticeToken: UUID?`.

- [ ] Render the compact entry only when the create draft has no smart-paste interpretation.
- [ ] Remove the filled-state branch and inline overflow menu from the old bar.
- [ ] Show a bottom overlay containing `已自动填充标题和 Prompt` and an Undo button.
- [ ] Start a four-second token-guarded dismissal task after `applySmartPaste(_:)`.
- [ ] Clear transient notice state when undoing, clearing, saving, or loading another draft.

### Task 3: Add persistent secondary actions to the header

**Files:**
- Modify: `Sources/PromptStudio/Views/Overlays.swift`

**Interfaces:**
- Consumes: the existing smart-paste session state and action functions.
- Produces: a create-only header `Menu` shown only after smart paste has been applied.

- [ ] Add `重新粘贴`, `查看原文与识别详情`, `撤销填充`, and `清除智能填充` to the header overflow menu.
- [ ] Keep the existing replacement-confirmation path for nonblank drafts.
- [ ] Keep the existing details popover attached to a stable composer container after removing the old bar.

### Task 4: Verify, package, and open

**Files:**
- Verify: `Scripts/test_prompt_smart_paste.sh`
- Verify: `Scripts/test_prompt_composer_simplification.sh`
- Verify: `Scripts/test_release_ui_copy.sh`

**Interfaces:**
- Consumes: completed UI behavior.
- Produces: a packaged Debug app containing the verified commit.

- [ ] Run all three UI regression scripts and `git diff --check`.
- [ ] Run `PromptStudioCoreUnitTests`, `PromptStudioSmokeTests`, and `swift build` with the compatible toolchain.
- [ ] Commit the implementation.
- [ ] Run `Scripts/build_app.sh debug`, terminate the old process, open the exact Debug app path, and verify the executable PID and build commit.

