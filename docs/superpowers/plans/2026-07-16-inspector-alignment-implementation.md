# Inspector Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align preview inspector content with the preview canvas top and preserve symmetric visible text padding beside overlay scrollbars.

**Architecture:** Add one shared immersive-preview content inset used by both left preview content and right inspector content. Add one explicit overlay-scroller clearance to the shared side-panel prompt layout, applied only to the scrolling AppKit prompt view so the existing 14pt text inset remains visually symmetric.

**Tech Stack:** SwiftUI, AppKit `NSScrollView`/`NSTextView`, shell-based UI regression checks, Swift Package Manager.

---

### Task 1: Add failing layout regression checks

**Files:**
- Modify: `Scripts/test_release_ui_copy.sh`
- Test: `Scripts/test_release_ui_copy.sh`

- [ ] **Step 1: Require a shared preview content inset**

Add checks requiring `ImmersivePreviewLayoutMetrics.contentInset`, two vertical-padding uses for left preview content, and two top-padding uses for media and Markdown inspectors. Reject the old `.padding(.top, 58)` values.

- [ ] **Step 2: Require overlay-scroller clearance**

Add checks requiring `SidePanelPromptBoxLayout.overlayScrollerClearance` and a non-zero right `contentInsets` value in `SidePanelPromptScrollableTextView.configure`.

- [ ] **Step 3: Verify RED**

Run:

```bash
bash Scripts/test_release_ui_copy.sh
```

Expected: FAIL with `Preview inspector content must align with the preview canvas top.` before production code changes.

### Task 2: Align immersive preview content tops

**Files:**
- Modify: `Sources/PromptStudio/Views/Overlays.swift`
- Test: `Scripts/test_release_ui_copy.sh`

- [ ] **Step 1: Add the shared inset**

Add:

```swift
private enum ImmersivePreviewLayoutMetrics {
    static let contentInset: CGFloat = 42
}
```

- [ ] **Step 2: Use it on both sides**

Replace both left preview `.padding(.vertical, 42)` calls with `.padding(.vertical, ImmersivePreviewLayoutMetrics.contentInset)`. Replace media and Markdown inspector `.padding(.top, 58)` calls with `.padding(.top, ImmersivePreviewLayoutMetrics.contentInset)`.

- [ ] **Step 3: Verify the first regression check passes**

Run `bash Scripts/test_release_ui_copy.sh`. It may still fail only if Task 3 has not yet added the scrollbar clearance.

### Task 3: Preserve symmetric visible Prompt padding

**Files:**
- Modify: `Sources/PromptStudio/Views/AssetSidePanelComponents.swift`
- Test: `Scripts/test_release_ui_copy.sh`

- [ ] **Step 1: Define the overlay scrollbar clearance**

Add:

```swift
static let overlayScrollerClearance: CGFloat = 10
```

to `SidePanelPromptBoxLayout`. The existing `textPadding` remains `14pt` on both sides.

- [ ] **Step 2: Reserve clearance only for scrolling text**

In `SidePanelPromptScrollableTextView.configure`, set:

```swift
scrollView.contentInsets = NSEdgeInsets(
    top: 0,
    left: 0,
    bottom: 0,
    right: SidePanelPromptBoxLayout.overlayScrollerClearance
)
```

Keep `scrollerInsets` zero so the overlay scroller remains attached to the right edge while the document content no longer runs beneath it.

- [ ] **Step 3: Verify GREEN**

Run:

```bash
bash Scripts/test_release_ui_copy.sh
```

Expected: `Release UI copy tests passed`.

### Task 4: Full verification and handoff

**Files:**
- Verify: `Sources/PromptStudio/Views/Overlays.swift`
- Verify: `Sources/PromptStudio/Views/AssetSidePanelComponents.swift`
- Verify: `Scripts/test_release_ui_copy.sh`

- [ ] **Step 1: Run automated verification**

Run the release UI, License Keychain, signing-policy and Swift-toolchain checks, then compatible Swift build, core tests, Smoke Test and debug app packaging.

- [ ] **Step 2: Manually inspect the application**

Open a long Prompt in the main inspector and verify its visible left/right text gaps match. Open image, video and Markdown previews and verify the right title top aligns with the left preview content top while the close button remains unchanged.

- [ ] **Step 3: Commit and push**

Commit the implementation as `Align inspector content and prompt padding`, push `codex/close-button-unification`, and verify local and remote commit hashes match.
