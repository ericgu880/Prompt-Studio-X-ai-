#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"
VIEW_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! /usr/bin/grep -Fq "$pattern" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if /usr/bin/grep -Fq "$pattern" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

require_pattern "$STATE_FILE" '@Published private(set) var selectedFolderIDs' \
    "AppState must keep a dedicated multi-folder selection."
require_pattern "$STATE_FILE" 'func selectFolders(ids:' \
    "AppState must expose an ordered multi-folder selection update."
require_pattern "$STATE_FILE" 'func moveFolders(' \
    "Folder drag/drop must submit the full folder selection."
require_pattern "$STATE_FILE" 'func beginDeleteSelectedFolders' \
    "Command+Backspace and context menus must delete the selected folder group."

require_pattern "$VIEW_FILE" 'static let promptStudioFolderIDs' \
    "Folder drag/drop must use a dedicated pasteboard type."
require_pattern "$VIEW_FILE" 'FolderDragPayload.pasteboardTypeIdentifier' \
    "Folder drag/drop must encode a versioned folder payload."
require_pattern "$VIEW_FILE" 'selectFolder: { [weak self] folderID, modifiers in' \
    "Native masonry folder cards must forward Command and Shift modifiers."
require_pattern "$VIEW_FILE" 'beginFolderDrag:' \
    "Native masonry folder cards must start a multi-folder drag session."
require_pattern "$VIEW_FILE" 'configureFolderDrag(' \
    "Folder cards must use the native hosting view as the AppKit drag source."
require_pattern "$VIEW_FILE" 'folderDragID != nil' \
    "The native hosting view must route folder mouse events into the shared drag session."
require_pattern "$VIEW_FILE" 'FolderDropTargetState' \
    "Each native folder card must own an observable drop-target state."
require_pattern "$VIEW_FILE" 'folderDropTargetState.isTargeted = isTargeted' \
    "AppKit drag enter/exit callbacks must update the folder card appearance."
require_pattern "$VIEW_FILE" 'folderDropTargetState.reset()' \
    "Reused folder cards must clear stale drop-target appearance."
require_pattern "$VIEW_FILE" 'canDropFolders:' \
    "Middle folder cards must validate folder payloads before showing an accepted state."
require_pattern "$VIEW_FILE" 'isDropTargeted ? StudioColor.primaryAction.opacity(0.16)' \
    "A valid middle-folder target must use the same subtle fill as the sidebar target."
reject_pattern "$VIEW_FILE" 'onDropTargeted: { _ in }' \
    "The native folder target callback must not discard drag-target state."
require_pattern "$VIEW_FILE" 'promptStudioFolderDragTextPrefix' \
    "Folder drags must publish a plain-text fallback so SwiftUI sidebar drop targets activate."
require_pattern "$VIEW_FILE" 'item.setString(dragText, forType: .string)' \
    "The folder payload owner must expose the plain-text fallback on its pasteboard item."
require_pattern "$VIEW_FILE" 'FolderDragPreviewPlan(' \
    "Multi-folder drag must build the shared stacked-preview plan."
require_pattern "$VIEW_FILE" 'case .folders' \
    "Marquee selection must lock to a folder-only selection domain."
require_pattern "$VIEW_FILE" 'UTType.promptStudioFolderIDs.identifier' \
    "Folder rows must accept the dedicated folder payload."
require_pattern "$VIEW_FILE" 'providers.first(where: {' \
    "Drop targets must locate the payload owner instead of assuming the first stacked preview owns data."
require_pattern "$VIEW_FILE" 'state.moveFolders(' \
    "Both sidebar and masonry drop targets must move the full folder payload."
require_pattern "$VIEW_FILE" 'event.modifierFlags.intersection([.command, .shift])' \
    "Folder click capture must preserve Finder-style selection modifiers."
require_pattern "$VIEW_FILE" 'FolderActionsContextMenu(folder: row.folder, usesMiddleFolderSelection: true)' \
    "Only middle folder cards may preserve a multi-folder context-menu selection."
require_pattern "$VIEW_FILE" 'primaryID: row.folder.id' \
    "Right-clicking a selected folder must make the clicked folder primary without collapsing the group."
require_pattern "$VIEW_FILE" 'animatesToStartingPositionsOnCancelOrFail = false' \
    "Cancelled folder drags must disappear immediately without a return animation."

echo "Folder multi-selection and drag regression tests passed"
