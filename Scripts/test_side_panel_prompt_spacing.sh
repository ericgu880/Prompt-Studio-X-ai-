#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/AssetSidePanelComponents.swift"
SCROLLER_FILE="$ROOT_DIR/Sources/PromptStudio/Views/TransparentOverlayScroller.swift"

if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "AssetSidePanelComponents.swift is missing." >&2
    exit 1
fi

for required in \
    'static let textLeadingPadding: CGFloat = 16' \
    'static let textToScrollerSpacing: CGFloat = 0' \
    'static let textTrailingPadding: CGFloat = TransparentOverlayScroller.knobWidth + textToScrollerSpacing' \
    'static let scrollerRightInset: CGFloat = 0' \
    'static let scrollContentRightInset: CGFloat = 0' \
    'override var textContainerOrigin: NSPoint' \
    'x: SidePanelPromptBoxLayout.textLeadingPadding' \
    'width - SidePanelPromptBoxLayout.textLeadingPadding - SidePanelPromptBoxLayout.textTrailingPadding' \
    'right: SidePanelPromptBoxLayout.scrollContentRightInset' \
    'right: SidePanelPromptBoxLayout.scrollerRightInset'; do
    if ! /usr/bin/grep -Fq "$required" "$SOURCE_FILE"; then
        echo "Missing side-panel Prompt spacing contract: $required" >&2
        exit 1
    fi
done

if ! /usr/bin/grep -Fq 'static let knobWidth: CGFloat = 6' "$SCROLLER_FILE"; then
    echo "The Prompt spacing contract assumes the visible scroller knob remains 6pt wide." >&2
    exit 1
fi

if /usr/bin/grep -Fq 'overlayScrollerClearance' "$SOURCE_FILE"; then
    echo "The old one-sided Prompt scroller clearance must be removed." >&2
    exit 1
fi

echo "Side-panel Prompt spacing regression tests passed"
