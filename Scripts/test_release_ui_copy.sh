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

if ! /usr/bin/grep -q 'static let sidebarCreateAction = Color(hex: 0xE8491F)' \
    "$ROOT_DIR/Sources/PromptStudio/Theme.swift" || \
   ! /usr/bin/grep -q 'StudioColor.sidebarCreateAction' \
    "$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"; then
    echo "The sidebar create CTA must keep its established orange accent instead of the white primary action token." >&2
    exit 1
fi

if /usr/bin/grep -q '无法建立安全连接，请检查系统时间后重试' \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseAPIClient.swift" || \
   ! /usr/bin/grep -q '授权服务的安全连接失败，请稍后重试或联系支持' \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseAPIClient.swift" || \
   ! /usr/bin/grep -q '系统时间可能不正确，请校准后重试' \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseAPIClient.swift"; then
    echo "License TLS failures must distinguish service failures from certificate date errors." >&2
    exit 1
fi

CLOSE_BUTTON_FILE="$ROOT_DIR/Sources/PromptStudio/Views/StudioCloseButton.swift"
if [[ ! -f "$CLOSE_BUTTON_FILE" ]] || \
   ! /usr/bin/grep -q 'static let diameter: CGFloat = 34' "$CLOSE_BUTTON_FILE" || \
   ! /usr/bin/grep -q 'static let topInset: CGFloat = 24' "$CLOSE_BUTTON_FILE" || \
   ! /usr/bin/grep -q 'static let trailingInset: CGFloat = 24' "$CLOSE_BUTTON_FILE" || \
   ! /usr/bin/grep -Fq '.ignoresSafeArea(.container, edges: [.top, .trailing])' "$CLOSE_BUTTON_FILE"; then
    echo "Page-level close buttons must share the 34pt control and 24pt top/trailing insets." >&2
    exit 1
fi

if [[ $(/usr/bin/grep -c '\.studioTopTrailingCloseButton' \
        "$ROOT_DIR/Sources/PromptStudio/Views/Overlays.swift") -ne 3 ]] || \
   [[ $(/usr/bin/grep -c '\.studioTopTrailingCloseButton' \
        "$ROOT_DIR/Sources/PromptStudio/Views/Sheets.swift") -ne 1 ]]; then
    echo "Media preview, Markdown preview, Prompt composer, and Settings must use the shared close-button placement." >&2
    exit 1
fi

PREVIEW_OVERLAY_FILE="$ROOT_DIR/Sources/PromptStudio/Views/Overlays.swift"
PREVIEW_HOST_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
if /usr/bin/grep -q '\.frame(width: 360)' "$PREVIEW_OVERLAY_FILE" || \
   [[ $(/usr/bin/grep -c 'let inspectorWidth: CGFloat' "$PREVIEW_OVERLAY_FILE") -ne 2 ]] || \
   [[ $(/usr/bin/grep -c '\.frame(width: inspectorWidth)' "$PREVIEW_OVERLAY_FILE") -ne 2 ]] || \
   ! /usr/bin/grep -q 'inspectorWidth: constrainedLayout(totalWidth: proxy.size.width).inspector' "$PREVIEW_HOST_FILE"; then
    echo "Media and Markdown previews must inherit the main layout's resolved inspector width." >&2
    exit 1
fi

if /usr/bin/grep -q '\.padding(\.top, 58)' "$PREVIEW_OVERLAY_FILE" || \
   ! /usr/bin/grep -q 'static let contentInset: CGFloat = 42' "$PREVIEW_OVERLAY_FILE" || \
   [[ $(/usr/bin/grep -c '\.padding(\.vertical, ImmersivePreviewLayoutMetrics\.contentInset)' "$PREVIEW_OVERLAY_FILE") -ne 2 ]] || \
   [[ $(/usr/bin/grep -c '\.padding(\.top, ImmersivePreviewLayoutMetrics\.contentInset)' "$PREVIEW_OVERLAY_FILE") -ne 2 ]]; then
    echo "Preview inspector content must align with the preview canvas top." >&2
    exit 1
fi

SIDE_PANEL_COMPONENT_FILE="$ROOT_DIR/Sources/PromptStudio/Views/AssetSidePanelComponents.swift"
if ! /usr/bin/grep -q 'static let overlayScrollerClearance: CGFloat = 10' "$SIDE_PANEL_COMPONENT_FILE" || \
   ! /usr/bin/grep -q 'right: SidePanelPromptBoxLayout\.overlayScrollerClearance' "$SIDE_PANEL_COMPONENT_FILE"; then
    echo "Scrollable Prompt text must reserve trailing space beside the overlay scroller." >&2
    exit 1
fi

MARKDOWN_EDITOR_FILE="$ROOT_DIR/Sources/PromptStudio/Views/MarkdownDocumentEditor.swift"
if ! /usr/bin/grep -q 'let availableTextWidth = max(' "$MARKDOWN_EDITOR_FILE" || \
   ! /usr/bin/grep -q 'scrollView.contentSize.width - textView.textContainerInset.width \* 2' "$MARKDOWN_EDITOR_FILE" || \
   ! /usr/bin/grep -q 'width: availableTextWidth' "$MARKDOWN_EDITOR_FILE"; then
    echo "Markdown preview must wrap inside the visible viewport after subtracting both text insets." >&2
    exit 1
fi

echo "Release UI copy tests passed"
