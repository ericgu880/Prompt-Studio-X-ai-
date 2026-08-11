#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "PromptStudioView.swift is missing." >&2
    exit 1
fi

if [[ "$(/usr/bin/grep -c 'applyIconCirclePalette()' "$SOURCE_FILE")" -ne 5 ]]; then
    echo "Image and Markdown card action buttons must all use the shared native circle palette." >&2
    exit 1
fi

if /usr/bin/grep -q 'actionHoverBorder\|\.applyPalette(' "$SOURCE_FILE"; then
    echo "Card action buttons must not keep independent hover palette configuration." >&2
    exit 1
fi

for required in \
    'static let actionButtonSize: CGFloat = 28' \
    'static let selection = NSColor(hex: 0x1F1F1F)' \
    'private var hoverBackground = NSColor.clear' \
    'isHovered || isPressed ? hoverBackground : normalBackground' \
    'NSWorkspace.shared.accessibilityDisplayShouldReduceMotion' \
    'let scale: CGFloat = reduceMotion ? 1' \
    'override func layout()' \
    'centerLayerGeometry()' \
    'layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)' \
    'layer.position = CGPoint(x: frame.midX, y: frame.midY)'; do
    if ! /usr/bin/grep -q "$required" "$SOURCE_FILE"; then
        echo "Missing native circle button hover contract: $required" >&2
        exit 1
    fi
done

echo "Card action hover regression tests passed"
