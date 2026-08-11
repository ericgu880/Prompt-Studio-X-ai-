#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/AssetSidePanelComponents.swift"
SCROLLER_FILE="$ROOT_DIR/Sources/PromptStudio/Views/TransparentOverlayScroller.swift"
INSPECTOR_FILE="$ROOT_DIR/Sources/PromptStudio/Views/InspectorView.swift"
OVERLAYS_FILE="$ROOT_DIR/Sources/PromptStudio/Views/Overlays.swift"

if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "AssetSidePanelComponents.swift is missing." >&2
    exit 1
fi

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

if ! /usr/bin/grep -Fq 'static let knobWidth: CGFloat = 6' "$SCROLLER_FILE"; then
    echo "The Prompt spacing contract assumes the visible scroller knob remains 6pt wide." >&2
    exit 1
fi

if /usr/bin/grep -Fq 'textTrailingPadding: CGFloat = TransparentOverlayScroller.knobWidth' "$SOURCE_FILE"; then
    echo "Image Prompt text padding must not be derived from the overlay scroller width." >&2
    exit 1
fi

if [[ "$(/usr/bin/grep -Fc 'SidePanelPromptTextBox(' "$INSPECTOR_FILE")" -ne 1 ]]; then
    echo "Every image inspector Prompt must use the shared SidePanelPromptTextBox." >&2
    exit 1
fi

if [[ "$(/usr/bin/grep -Fc 'SidePanelPromptTextBox(' "$OVERLAYS_FILE")" -ne 2 ]]; then
    echo "Image preview Prompt surfaces must use the shared SidePanelPromptTextBox." >&2
    exit 1
fi

if /usr/bin/grep -Fq 'MidjourneyPromptInfoPanel' "$INSPECTOR_FILE"; then
    echo "The legacy image Prompt panel bypasses the shared symmetric spacing contract." >&2
    exit 1
fi

echo "Side-panel Prompt spacing regression tests passed"
