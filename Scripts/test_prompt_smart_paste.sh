#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_STATE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"
BRIDGE_FILE="$ROOT_DIR/Sources/PromptStudio/AppKitBridge.swift"
APP_FILE="$ROOT_DIR/Sources/PromptStudio/PromptStudioApp.swift"
OVERLAY_FILE="$ROOT_DIR/Sources/PromptStudio/Views/Overlays.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! /usr/bin/grep -Fq "$pattern" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

require_pattern "$BRIDGE_FILE" \
    'static func pasteboardPlainText() -> String?' \
    "AppKitBridge must expose raw pasteboard plain-text access."
require_pattern "$BRIDGE_FILE" \
    'pasteboard.string(forType: .string)' \
    "AppKitBridge plain-text access must read the .string pasteboard type."
require_pattern "$APP_STATE_FILE" \
    'struct PromptComposerPrefill' \
    "AppState must carry a tokenized Prompt composer prefill."
require_pattern "$APP_STATE_FILE" \
    'case create(prefill: PromptComposerPrefill?)' \
    "Prompt composer create mode must carry optional prefill state."
require_pattern "$APP_STATE_FILE" \
    'func routePasteCommand()' \
    "Paste routing must be centralized in AppState."
require_pattern "$APP_STATE_FILE" \
    '@Published var pendingSmartPasteRequest: PromptComposerPrefill?' \
    "Smart paste must queue a one-shot request for an already-open composer."
require_pattern "$APP_STATE_FILE" \
    'func consumeSmartPasteRequest(token: UUID)' \
    "Smart paste requests must be consumed after the overlay handles them."
require_pattern "$APP_FILE" \
    'appState.routePasteCommand()' \
    "The CommandGroup paste action must call the centralized AppState route."
require_pattern "$OVERLAY_FILE" \
    'smartPasteBarHeight: CGFloat = 44' \
    "Prompt composer must reserve a compact 44pt smart-paste bar."
require_pattern "$OVERLAY_FILE" \
    'smartPastePromptHeightBudget: CGFloat = 266' \
    "Prompt composer must use the 266pt prompt-height budget."
require_pattern "$OVERLAY_FILE" \
    '.popover(isPresented: $showSmartPasteDetails)' \
    "Smart-paste details must use a transient popover."
require_pattern "$OVERLAY_FILE" \
    'initialSignature = draftSignature' \
    "Prompt composer must capture the clean initial draft signature."
require_pattern "$OVERLAY_FILE" \
    'confirmationDialog("覆盖当前草稿？"' \
    "Replacing a dirty draft from smart paste must require confirmation."
require_pattern "$OVERLAY_FILE" \
    'undoSmartPaste' \
    "Smart-paste sessions must expose undo-fill behavior."
require_pattern "$OVERLAY_FILE" \
    'handleIncomingSmartPaste' \
    "Incoming app-level smart-paste requests must share the bar replacement flow."
require_pattern "$OVERLAY_FILE" \
    '.onChange(of: state.pendingSmartPasteRequest?.token)' \
    "Prompt composer must observe queued smart-paste requests without rebuilding the draft."
require_pattern "$OVERLAY_FILE" \
    'ScrollView {' \
    "Smart-paste details must offer complete, selectable original text in a bounded scroll view."
require_pattern "$OVERLAY_FILE" \
    'Text(interpretation.originalText)' \
    "Smart-paste details must render the full original text."
require_pattern "$OVERLAY_FILE" \
    '.textSelection(.enabled)' \
    "Smart-paste original text must be selectable."
require_pattern "$OVERLAY_FILE" \
    'let promptHeight = max(240, contentHeight - promptHeightBudget)' \
    "Prompt composer must preserve the 240pt minimum prompt height."

echo "Prompt smart-paste UI regression tests passed"
