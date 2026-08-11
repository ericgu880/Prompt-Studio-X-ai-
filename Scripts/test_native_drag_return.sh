#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "PromptStudioView.swift is missing." >&2
    exit 1
fi

for required in \
    'private struct NativeDragReturnContext' \
    'private enum NativeDragReturnAnimator' \
    'private final class NativeDragReturnGhostView' \
    'override func hitTest(_ point: NSPoint) -> NSView? { nil }' \
    'static let duration: TimeInterval = 0.22' \
    'NSWorkspace.shared.accessibilityDisplayShouldReduceMotion' \
    'session.animatesToStartingPositionsOnCancelOrFail = false' \
    'operation == []' \
    'NativeDragReturnAnimator.animate' \
    'NativeDragReturnAnimator.cancel(in: window)' \
    'func draggingSession(' \
    'endedAt screenPoint: NSPoint' \
    'sourceFrameInWindow' \
    'pointerOffsetInWindow'; do
    if ! /usr/bin/grep -Fq "$required" "$SOURCE_FILE"; then
        echo "Missing native drag return contract: $required" >&2
        exit 1
    fi
done

for card in NativeImageCardView NativeMarkdownCardView; do
    start_line=$(/usr/bin/grep -n "private final class $card" "$SOURCE_FILE" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
    next_line=$(/usr/bin/tail -n +$((start_line + 1)) "$SOURCE_FILE" | /usr/bin/grep -n '^private \(final \)\?class\|^private struct\|^private enum' | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1 || true)
    if [[ -n "$next_line" ]]; then
        end_line=$((start_line + next_line - 1))
    else
        end_line=$(/usr/bin/wc -l < "$SOURCE_FILE")
    fi
    card_source=$(/usr/bin/sed -n "${start_line},${end_line}p" "$SOURCE_FILE")
    if ! /usr/bin/grep -Fq 'func draggingSession(' <<<"$card_source" || \
       ! /usr/bin/grep -Fq 'endedAt screenPoint: NSPoint' <<<"$card_source" || \
       ! /usr/bin/grep -Fq 'NativeDragReturnAnimator.animate' <<<"$card_source"; then
        echo "${card} must replace the system return animation with the shared non-interactive ghost." >&2
        exit 1
    fi
done

echo "Native drag return regression tests passed"
