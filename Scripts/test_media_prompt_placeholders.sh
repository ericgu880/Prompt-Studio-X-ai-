#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_STATE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"
BRIDGE="$ROOT_DIR/Sources/PromptStudio/AppKitBridge.swift"
OVERLAYS="$ROOT_DIR/Sources/PromptStudio/Views/Overlays.swift"
PROMPT_VIEW="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
INSPECTOR="$ROOT_DIR/Sources/PromptStudio/Views/InspectorView.swift"
SHEETS="$ROOT_DIR/Sources/PromptStudio/Views/Sheets.swift"
UI_HELPER="$ROOT_DIR/Sources/PromptStudio/Views/PromptAssetUI.swift"

require_pattern() {
    local file="$1" pattern="$2" message="$3"
    if ! /usr/bin/grep -qE "$pattern" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

require_pattern "$UI_HELPER" 'PromptVirtualCover' "Shared virtual cover is missing."
require_pattern "$UI_HELPER" '尚未添加主素材' "Virtual cover must explain that the primary asset is missing."
require_pattern "$APP_STATE" 'PrimaryAssetUpdate' "App state must model an unambiguous primary-asset update."
require_pattern "$OVERLAYS" 'case \.edit\(let itemID\)' "Composer edits must retain the stable item ID."
require_pattern "$APP_STATE" 'func savePrompt\([[:space:]]*$' "App state must expose an item-scoped edit save API."
require_pattern "$APP_STATE" 'migratePromptPlaceholders' "Repository placeholder migration must run during app load."
require_pattern "$APP_STATE" 'guard item\.hasAvailablePrimaryAsset' "File operations must guard missing primary assets."
require_pattern "$BRIDGE" 'choosePrimaryAsset' "The picker must support one image, video, or audio primary asset."
require_pattern "$OVERLAYS" 'primaryAssetURL' "The composer must use a generic primary asset URL."
require_pattern "$OVERLAYS" '素材类型与当前类型不同' "Mismatched primary assets must ask whether to switch type or become references."
require_pattern "$OVERLAYS" '转为参考资产' "Existing primary assets must support preservation as references."
require_pattern "$OVERLAYS" '确认删除旧主素材' "Deleting an existing primary asset must require a second confirmation."
require_pattern "$PROMPT_VIEW" 'PromptVirtualCover' "The main grid must render the shared placeholder cover."
require_pattern "$PROMPT_VIEW" 'hasAvailablePrimaryAsset' "The main grid must guard real-file actions."
require_pattern "$INSPECTOR" 'PromptVirtualCover' "The inspector must render the shared placeholder cover."
require_pattern "$SHEETS" 'primaryAssetURL' "Sheets must no longer use an image-only primary asset API."
require_pattern "$APP_STATE" 'failedCount' "Migration failures must be logged without blocking library load."
require_pattern "$PROMPT_VIEW" 'hasAvailablePrimaryAsset' "Thumbnail prefetch and native image cards must require an available file."
require_pattern "$APP_STATE" 'appendingPathComponent\("\\\(UUID\(\)\.uuidString\)-\\\(baseName\)\.md"\)' "Text prompts must persist a real Markdown primary asset."

if /usr/bin/grep -q 'textPromptFileExtension' "$APP_STATE"; then
    echo "Text prompt primary assets must not vary away from Markdown." >&2
    exit 1
fi

if /usr/bin/grep -R -n 'previewImageURL' "$ROOT_DIR/Sources/PromptStudio" >/dev/null; then
    echo "Legacy previewImageURL primary asset state remains." >&2
    exit 1
fi

echo "Media prompt placeholder regression tests passed"
