#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY_FILE="$ROOT_DIR/Sources/PromptStudio/Views/Overlays.swift"
APP_STATE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! /usr/bin/grep -Fq "$pattern" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

for removed in \
    'private var createTypeTabs' \
    'private var createModelMenu' \
    'private var createFormatMenu' \
    'private struct CreateComposerTypeTab' \
    'private struct PromptFormatOption'; do
    if /usr/bin/grep -Fq "$removed" "$OVERLAY_FILE"; then
        echo "Prompt composer must remove the legacy type/model/format control: $removed" >&2
        exit 1
    fi
done

header_count="$(/usr/bin/grep -Fc 'createHeaderControls(width: leftWidth)' "$OVERLAY_FILE")"
if [[ "$header_count" -ne 1 ]]; then
    echo "Prompt composer must render its header controls exactly once; found $header_count." >&2
    exit 1
fi

require_pattern "$OVERLAY_FILE" \
    'private var createTypeStatusMenu' \
    "Prompt composer must expose the compact type status menu."
require_pattern "$OVERLAY_FILE" \
    'return "请选择类型"' \
    "Low-confidence drafts must visibly request one type selection."
require_pattern "$OVERLAY_FILE" \
    '恢复自动识别' \
    "A manually selected type must offer a way back to automatic inference."
require_pattern "$OVERLAY_FILE" \
    'Task.sleep(for: .milliseconds(500))' \
    "Manual typing inference must use the specified 500ms debounce."
require_pattern "$OVERLAY_FILE" \
    'Menu {' \
    "Smart-paste secondary actions must be collected in a menu."
require_pattern "$OVERLAY_FILE" \
    'Image(systemName: "ellipsis")' \
    "Smart-paste secondary actions must use the compact ellipsis affordance."
require_pattern "$OVERLAY_FILE" \
    '.disabled(!canSubmitPrompt)' \
    "Create/save must be disabled while the Prompt type is unresolved."
require_pattern "$OVERLAY_FILE" \
    'private var automaticInferenceTaskID' \
    "Smart-paste inference must not be overwritten by the manual typing debounce."
require_pattern "$OVERLAY_FILE" \
    'guard smartPasteInterpretation == nil || prompt != smartPasteAppliedPrompt else { return }' \
    "The debounce callback must explicitly preserve an unedited smart-paste interpretation."
require_pattern "$OVERLAY_FILE" \
    'private func restoreAutomaticTypeInference()' \
    "Restoring automatic mode must support an unedited smart-paste interpretation."
require_pattern "$OVERLAY_FILE" \
    'private func moveUnsavedPreviewImageToReferencesIfNeeded()' \
    "Text type selection must not retain an incompatible unsaved preview image."
move_count="$(/usr/bin/grep -Fc 'moveUnsavedPreviewImageToReferencesIfNeeded()' "$OVERLAY_FILE")"
if [[ "$move_count" -lt 4 ]]; then
    echo "Manual, automatic, and smart-paste text resolution must all migrate an unsaved preview image." >&2
    exit 1
fi
require_pattern "$OVERLAY_FILE" \
    'if let previousType, previousType != resolvedType {' \
    "Changing Prompt type must clear parameters from the old type."
require_pattern "$OVERLAY_FILE" \
    'if previousType != nil {' \
    "Clearing a previously classified Prompt must not retain parameters from the old type."
require_pattern "$OVERLAY_FILE" \
    'guard shouldShowPreviewImage else {' \
    "An asynchronous image picker/drop must not restore a hidden text preview image."
require_pattern "$APP_STATE_FILE" \
    'modelId: String?' \
    "Prompt creation must accept an optional automatically resolved model."
require_pattern "$APP_STATE_FILE" \
    'if type == .text, item.type != .text {' \
    "Editing an existing asset to text must create a compatible text primary asset."

echo "Prompt composer simplification regression tests passed"
