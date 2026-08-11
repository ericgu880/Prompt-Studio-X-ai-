# Image Prompt Symmetric Insets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every image right-side Prompt render with symmetric `24pt` text insets while the `6pt` overlay scroller remains flush to the right edge and never changes text wrapping.

**Architecture:** Keep `SidePanelPromptTextBox` as the only image Prompt renderer. Decouple its text-container insets from `TransparentOverlayScroller.knobWidth`: both static and scrollable text paths consume fixed `24pt` leading/trailing insets, while the overlay scroller independently keeps `0pt` right inset.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSTextView`/`NSScrollView`, shell source-regression checks, Swift Package Manager.

## Global Constraints

- Left boundary to Prompt text: exactly `24pt`.
- Prompt text to right boundary: exactly `24pt`.
- Overlay scroller width: `TransparentOverlayScroller.knobWidth`, currently `6pt`.
- Overlay scroller to right boundary: exactly `0pt`.
- The scroller must not participate in text-container width or alter line wrapping when it appears.
- Main image inspector, immersive image preview, and create/edit image preview must continue using `SidePanelPromptTextBox`.
- Do not change MD document layout, Prompt typography, vertical padding, copy interactions, Hover feedback, or panel width synchronization.
- Preserve all pre-existing uncommitted user changes in the worktree.

---

### Task 1: Decouple Image Prompt Text Insets from the Overlay Scroller

**Files:**
- Modify: `Sources/PromptStudio/Views/AssetSidePanelComponents.swift:5-13`
- Modify: `Scripts/test_side_panel_prompt_spacing.sh:12-55`
- Modify: `Scripts/test_release_ui_copy.sh:101-112`
- Verify unchanged consumers: `Sources/PromptStudio/Views/InspectorView.swift:403-424`
- Verify unchanged consumers: `Sources/PromptStudio/Views/Overlays.swift:295-316,1356-1368`

**Interfaces:**
- Consumes: `TransparentOverlayScroller.knobWidth: CGFloat` only for rendering the overlay scroller itself; text layout must not derive padding from it.
- Produces: `SidePanelPromptBoxLayout.textLeadingPadding == 24`, `SidePanelPromptBoxLayout.textTrailingPadding == 24`, `SidePanelPromptBoxLayout.scrollerRightInset == 0`, and `SidePanelPromptBoxLayout.scrollContentRightInset == 0`.
- Preserves: `SidePanelPromptTextBox(text:maxHeight:resetID:isPlaceholder:isInteractive:isHovered:copyFeedback:idleHint:doneHint:onCopyAll:onCopySelection:)`.

- [ ] **Step 1: Update the source-regression checks first**

In `Scripts/test_side_panel_prompt_spacing.sh`, replace the old coupled spacing expectations with:

```bash
for required in \
    'static let textLeadingPadding: CGFloat = 24' \
    'static let textTrailingPadding: CGFloat = 24' \
    'static let scrollerRightInset: CGFloat = 0' \
    'static let scrollContentRightInset: CGFloat = 0' \
    'override var textContainerOrigin: NSPoint' \
    'x: SidePanelPromptBoxLayout.textLeadingPadding' \
    'width - SidePanelPromptBoxLayout.textLeadingPadding - SidePanelPromptBoxLayout.textTrailingPadding' \
    'right: SidePanelPromptBoxLayout.scrollContentRightInset' \
    'right: SidePanelPromptBoxLayout.scrollerRightInset'; do
    if ! /usr/bin/grep -Fq "$required" "$SOURCE_FILE"; then
        echo "Missing symmetric image Prompt spacing contract: $required" >&2
        exit 1
    fi
done

if /usr/bin/grep -Fq 'textTrailingPadding: CGFloat = TransparentOverlayScroller.knobWidth' "$SOURCE_FILE"; then
    echo "Image Prompt text padding must not be derived from the overlay scroller width." >&2
    exit 1
fi
```

Keep the existing checks that enforce one `SidePanelPromptTextBox` use in `InspectorView.swift`, two uses in `Overlays.swift`, no `MidjourneyPromptInfoPanel`, and a `6pt` scroller knob.

In `Scripts/test_release_ui_copy.sh`, replace the image Prompt spacing assertions with:

```bash
if ! /usr/bin/grep -q 'static let textLeadingPadding: CGFloat = 24' "$SIDE_PANEL_COMPONENT_FILE" || \
   ! /usr/bin/grep -q 'static let textTrailingPadding: CGFloat = 24' "$SIDE_PANEL_COMPONENT_FILE" || \
   ! /usr/bin/grep -q 'static let scrollerRightInset: CGFloat = 0' "$SIDE_PANEL_COMPONENT_FILE" || \
   ! /usr/bin/grep -q 'static let scrollContentRightInset: CGFloat = 0' "$SIDE_PANEL_COMPONENT_FILE" || \
   ! /usr/bin/grep -q 'right: SidePanelPromptBoxLayout\.scrollContentRightInset' "$SIDE_PANEL_COMPONENT_FILE" || \
   ! /usr/bin/grep -q 'right: SidePanelPromptBoxLayout\.scrollerRightInset' "$SIDE_PANEL_COMPONENT_FILE"; then
    echo "Image Prompt text must keep symmetric 24pt insets while the scroller stays on the right edge." >&2
    exit 1
fi
```

- [ ] **Step 2: Run the regression checks and verify the intended failure**

Run:

```bash
bash Scripts/test_side_panel_prompt_spacing.sh
bash Scripts/test_release_ui_copy.sh
```

Expected: both commands fail because the current source still contains `textLeadingPadding: CGFloat = 16` and derives `textTrailingPadding` from `TransparentOverlayScroller.knobWidth`.

- [ ] **Step 3: Implement fixed symmetric text insets**

In `Sources/PromptStudio/Views/AssetSidePanelComponents.swift`, replace the top-level layout constants with:

```swift
enum SidePanelPromptBoxLayout {
    static let textLeadingPadding: CGFloat = 24
    static let textTrailingPadding: CGFloat = 24
    static let textVerticalPadding: CGFloat = 14
    static let scrollerRightInset: CGFloat = 0
    static let scrollContentRightInset: CGFloat = 0
    static let bottomReserveAfterLastLine: CGFloat = 32
    static let copyHintHeight: CGFloat = 24
    static let copyHintOuterPadding: CGFloat = 8

    static var copyHintFullHeight: CGFloat {
        copyHintHeight + copyHintOuterPadding * 2
    }

    static var protectedBottomArea: CGFloat {
        bottomReserveAfterLastLine + copyHintFullHeight
    }

    static var extraBottomClearance: CGFloat {
        max(0, protectedBottomArea - textVerticalPadding)
    }
}
```

Do not alter the existing width calculations. They already subtract `textLeadingPadding + textTrailingPadding` in the measurement path, non-scrolling `NSTextView` path, and scrolling document-view path. Do not alter `NSScrollView.contentInsets` or `NSScrollView.scrollerInsets`; both continue reading the independent `0pt` constants.

- [ ] **Step 4: Run focused regressions and inspect the diff**

Run:

```bash
bash Scripts/test_side_panel_prompt_spacing.sh
bash Scripts/test_release_ui_copy.sh
git diff --check
git diff -- Sources/PromptStudio/Views/AssetSidePanelComponents.swift Scripts/test_side_panel_prompt_spacing.sh Scripts/test_release_ui_copy.sh
```

Expected: both regression scripts pass, `git diff --check` is silent, and the Swift diff changes only the two horizontal text-padding constants/removes the coupled spacing constant.

- [ ] **Step 5: Build and run automated verification**

Run:

```bash
source Scripts/swift_toolchain.sh
PROMPTSTUDIO_SWIFT="$(find_compatible_swift_tool swift)"
"$PROMPTSTUDIO_SWIFT" build
"$PROMPTSTUDIO_SWIFT" run PromptStudioCoreUnitTests
"$PROMPTSTUDIO_SWIFT" run PromptStudioSmokeTests
Scripts/build_app.sh debug
```

Expected: Debug build, `PromptStudioCoreUnitTests`, and `PromptStudioSmokeTests` pass. Existing `NSImage` Sendable and deprecated AVFoundation warnings may remain; no new warning may originate from the changed files.

- [ ] **Step 6: Reopen the exact Debug app and verify the process path**

Run:

```bash
/usr/bin/pkill -x PromptStudio || true
/usr/bin/open -na /Users/guruocen/.config/superpowers/worktrees/PromptStudio/close-button-unification/.build/arm64-apple-macosx/debug/PromptStudio.app
/bin/sleep 3
PID="$(/usr/bin/pgrep -x PromptStudio | /usr/bin/tail -n 1)"
/bin/ps -p "$PID" -o command=
```

Expected process path:

```text
/Users/guruocen/.config/superpowers/worktrees/PromptStudio/close-button-unification/.build/arm64-apple-macosx/debug/PromptStudio.app/Contents/MacOS/PromptStudio
```

Manually inspect one short and one long image Prompt in both the main inspector and immersive preview. The text must remain `24pt` from each panel edge, the scroller must sit on the right edge, and the long Prompt must wrap at the same x-position whether the scroller is visible or hidden.

- [ ] **Step 7: Commit the approved spacing work without staging unrelated files**

Because `Scripts/test_release_ui_copy.sh` already contains approved MD-spacing regression updates in the current dirty worktree, include the corresponding approved MD implementation files so the commit remains self-consistent:

```bash
git add \
  Sources/PromptStudio/Views/AssetSidePanelComponents.swift \
  Sources/PromptStudio/Views/InspectorView.swift \
  Sources/PromptStudio/Views/MarkdownDocumentEditor.swift \
  Sources/PromptStudio/Views/Overlays.swift \
  Scripts/test_side_panel_prompt_spacing.sh \
  Scripts/test_release_ui_copy.sh
git commit -m "Refine Prompt and Markdown text spacing"
```

Expected: one commit containing only the previously approved Prompt/MD display work; the design and plan documents remain in their own commits.
