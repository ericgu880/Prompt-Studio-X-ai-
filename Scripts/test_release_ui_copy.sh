#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if /usr/bin/grep -R -n -E 'MVP|Create New Prompt|https://promptstudio\.app/pricing' \
    "$ROOT_DIR/Sources/PromptStudio" >/dev/null; then
    echo "Release UI still contains internal-stage copy, mixed-language primary CTA, or the cloud pricing URL." >&2
    exit 1
fi

if /usr/bin/grep -q '选择瀑布流中的图片后' \
    "$ROOT_DIR/Sources/PromptStudio/Views/InspectorView.swift"; then
    echo "Inspector empty-state copy must cover every supported asset type, not only images." >&2
    exit 1
fi

if ! /usr/bin/grep -q 'LicenseRuntimeConfiguration.purchaseURL' \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseSettingsView.swift"; then
    echo "License purchase actions must use the validated release configuration." >&2
    exit 1
fi

if ! /usr/bin/grep -q 'if selectedPage == \.shortcuts' \
    "$ROOT_DIR/Sources/PromptStudio/Views/Sheets.swift"; then
    echo "Settings save/reset controls must only appear on the editable shortcuts page." >&2
    exit 1
fi

if ! /usr/bin/grep -q 'loadDraftFromCurrentFilter' \
    "$ROOT_DIR/Sources/PromptStudio/Views/Sheets.swift"; then
    echo "Advanced filters must reopen from the user's active filter state." >&2
    exit 1
fi

if ! /usr/bin/grep -q 'guard filter != PromptFilter()' \
    "$ROOT_DIR/Sources/PromptStudio/AppState.swift"; then
    echo "Clear filters must reset query, collection, and every advanced condition." >&2
    exit 1
fi

if ! /usr/bin/grep -q 'isLibraryEmpty' \
    "$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"; then
    echo "Empty-library and no-filter-results states must be presented separately." >&2
    exit 1
fi

echo "Release UI copy tests passed"
