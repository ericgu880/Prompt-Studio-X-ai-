#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_MARQUEE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/NativeMarqueeCollectionView.swift"
PROMPT_STUDIO_VIEW_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
APP_STATE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"

extract_scoped_region() {
    local file="$1"
    local start_pattern="$2"
    local end_pattern="$3"
    local label="$4"

    /usr/bin/perl -e '
        use strict;
        use warnings;
        my ($start_pattern, $end_pattern, $label) = @ARGV;
        my @lines = <STDIN>;
        my @starts = grep { $lines[$_] =~ /$start_pattern/ } 0 .. $#lines;
        if (@starts != 1) {
            print STDERR "$label start marker must appear exactly once.\n";
            exit 1;
        }
        my @ordered_ends = grep {
            $_ > $starts[0] && $lines[$_] =~ /$end_pattern/
        } 0 .. $#lines;
        if (!@ordered_ends) {
            print STDERR "$label must have an end marker after its start marker.\n";
            exit 1;
        }
        print @lines[$starts[0] .. $ordered_ends[0] - 1];
    ' "$start_pattern" "$end_pattern" "$label" < "$file"
}

extract_braced_declaration() {
    local file="$1"
    local declaration_pattern="$2"
    local label="$3"

    /usr/bin/perl -0e '
        use strict;
        use warnings;
        my ($pattern, $label) = @ARGV;
        my $source = <STDIN>;
        my @starts;
        while ($source =~ /$pattern/gm) { push @starts, $-[0]; }
        if (@starts != 1) {
            print STDERR "$label declaration marker must appear exactly once.\n";
            exit 1;
        }
        my $open = index($source, "{", $starts[0]);
        if ($open < 0) {
            print STDERR "$label declaration must have a brace-delimited body.\n";
            exit 1;
        }
        my ($depth, $state, $escape) = (0, "code", 0);
        for (my $i = $open; $i < length($source); $i++) {
            my $char = substr($source, $i, 1);
            my $next = substr($source, $i + 1, 1);
            if ($state eq "line_comment") {
                $state = "code" if $char eq "\n";
                next;
            }
            if ($state eq "block_comment") {
                if ($char eq "*" && $next eq "/") { $state = "code"; $i++; }
                next;
            }
            if ($state eq "string") {
                if ($escape) { $escape = 0; next; }
                if ($char eq "\\") { $escape = 1; next; }
                $state = "code" if $char eq "\"";
                next;
            }
            if ($char eq "/" && $next eq "/") { $state = "line_comment"; $i++; next; }
            if ($char eq "/" && $next eq "*") { $state = "block_comment"; $i++; next; }
            if ($char eq "\"") { $state = "string"; next; }
            $depth++ if $char eq "{";
            if ($char eq "}") {
                $depth--;
                if ($depth == 0) {
                    print substr($source, $starts[0], $i - $starts[0] + 1);
                    exit 0;
                }
            }
        }
        print STDERR "$label declaration body is not brace-balanced.\n";
        exit 1;
    ' "$declaration_pattern" "$label" < "$file"
}

normalize_swift() {
    /usr/bin/perl -0pe '
        s{ /\* .*? \*/ }{}gsx;
        s{//[^\r\n]*}{}g;
        s/\s+/ /g;
        s/^\s+|\s+$//g;
    '
}

contains_normalized_token() {
    local normalized_source="$1"
    local token="$2"
    [[ "$normalized_source" == *"$token"* ]]
}

require_normalized_token() {
    local normalized_source="$1"
    local token="$2"
    local message="$3"

    if ! contains_normalized_token "$normalized_source" "$token"; then
        echo "$message" >&2
        exit 1
    fi
}

require_normalized_pattern() {
    local normalized_source="$1"
    local pattern="$2"
    local message="$3"

    if ! /usr/bin/grep -Eq "$pattern" <<<"$normalized_source"; then
        echo "$message" >&2
        exit 1
    fi
}

run_self_tests() {
    local fixture
    local region
    local normalized
    fixture="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/native-marquee-contract.XXXXXX")"
    trap 'rm -f "$fixture"' EXIT

    printf '%s\n' \
        'private struct MasonryCollectionGridView: NSViewRepresentable {' \
        '    let grid = NativeMarqueeCollectionView(' \
        '        frame: .zero' \
        '    )' \
        '    let nearestRegion = true' \
        '}' \
        'private final class MasonryCollectionLayout: NSCollectionViewLayout {}' \
        'let outsideNearestRegion = true' \
        'private final class MasonryCollectionLayout: NSCollectionViewLayout {}' > "$fixture"
    region="$(extract_scoped_region "$fixture" \
        '^[[:space:]]*((public|private|fileprivate|internal|open)[[:space:]]+)*(struct|final[[:space:]]+class|class)[[:space:]]+MasonryCollectionGridView\b' \
        '^[[:space:]]*((public|private|fileprivate|internal|open)[[:space:]]+)*(struct|final[[:space:]]+class|class)[[:space:]]+MasonryCollectionLayout\b' \
        'MasonryCollectionGridView self-test')"
    normalized="$(printf '%s' "$region" | normalize_swift)"
    if ! /usr/bin/grep -Eq 'NativeMarqueeCollectionView\( ?frame: \.zero' <<<"$normalized"; then
        echo "Self-test failed: multiline NativeMarqueeCollectionView constructor was not recognized." >&2
        exit 1
    fi
    if ! contains_normalized_token "$normalized" 'let nearestRegion = true' || \
       contains_normalized_token "$normalized" 'outsideNearestRegion'; then
        echo "Self-test failed: scoped extraction did not stop at the nearest end marker." >&2
        exit 1
    fi

    normalized="$(printf '%s\n' '// NativeMarqueeCollectionView(frame: .zero)' | normalize_swift)"
    if contains_normalized_token "$normalized" 'NativeMarqueeCollectionView( frame: .zero'; then
        echo "Self-test failed: comment-only constructor token was recognized." >&2
        exit 1
    fi

    printf '%s\n' 'struct DeleteSelectionKeyMonitor {}' > "$fixture"
    if extract_scoped_region "$fixture" '^struct DeleteSelectionKeyMonitor\b' \
        '^struct StandardTextEditingShortcutMonitor\b' 'DeleteSelectionKeyMonitor self-test' >/dev/null 2>&1; then
        echo "Self-test failed: missing end sentinel was accepted." >&2
        exit 1
    fi

    rm -f "$fixture"
    trap - EXIT
    echo "Native marquee multi-selection regression self-tests passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
    run_self_tests
    exit 0
fi

if [[ ! -f "$NATIVE_MARQUEE_FILE" ]]; then
    echo "Native marquee collection view source is missing: $NATIVE_MARQUEE_FILE" >&2
    exit 1
fi

MASONRY_GRID_REGION="$(extract_scoped_region "$PROMPT_STUDIO_VIEW_FILE" \
    '^[[:space:]]*((public|private|fileprivate|internal|open)[[:space:]]+)*(struct|final[[:space:]]+class|class)[[:space:]]+MasonryCollectionGridView\b' \
    '^[[:space:]]*((public|private|fileprivate|internal|open)[[:space:]]+)*(struct|final[[:space:]]+class|class)[[:space:]]+MasonryCollectionLayout\b' \
    'MasonryCollectionGridView')"
MASONRY_GRID_NORMALIZED="$(printf '%s' "$MASONRY_GRID_REGION" | normalize_swift)"
require_normalized_pattern "$MASONRY_GRID_NORMALIZED" 'NativeMarqueeCollectionView\( ?frame: \.zero' \
    "PromptStudioView must host NativeMarqueeCollectionView(frame: .zero)."
require_normalized_token "$MASONRY_GRID_NORMALIZED" 'onMarqueeChange' \
    "PromptStudioView must handle native marquee selection changes."
require_normalized_token "$MASONRY_GRID_NORMALIZED" 'indexPathsForItems(in: rect)' \
    "Native marquee selection must use indexPathsForItems(in: rect)."

NATIVE_MARQUEE_REGION="$(extract_braced_declaration "$NATIVE_MARQUEE_FILE" \
    '^[[:space:]]*((public|private|fileprivate|internal|open)[[:space:]]+)*(struct|final[[:space:]]+class|class)[[:space:]]+NativeMarqueeCollectionView\b' \
    'NativeMarqueeCollectionView')"
NATIVE_MARQUEE_NORMALIZED="$(printf '%s' "$NATIVE_MARQUEE_REGION" | normalize_swift)"
require_normalized_token "$NATIVE_MARQUEE_NORMALIZED" 'onMarqueeChange' \
    "Native marquee collection view must expose marquee callbacks."

require_normalized_token "$MASONRY_GRID_NORMALIZED" 'collectionView.isSelectable = true' \
    "The native collection view must own a selectable multi-selection surface."
require_normalized_token "$MASONRY_GRID_NORMALIZED" 'collectionView.allowsMultipleSelection = true' \
    "The native collection view must allow multiple selection."
require_normalized_token "$MASONRY_GRID_NORMALIZED" 'let context = actionContext(for: itemID)' \
    "The collection coordinator must resolve one shared action context."
require_normalized_token "$MASONRY_GRID_NORMALIZED" 'promptStudioPasteboardItem(itemIDs: context.orderedItemIDs)' \
    "The collection coordinator must publish the complete ordered selection."
require_normalized_token "$MASONRY_GRID_NORMALIZED" 'collectionView.beginDraggingSession' \
    "The collection view must own the shared drag session."

SIDEBAR_DROP_REGION="$(extract_scoped_region "$PROMPT_STUDIO_VIEW_FILE" \
    '^[[:space:]]*private[[:space:]]+func[[:space:]]+handleDrop\b' \
    '^[[:space:]]*private[[:space:]]+func[[:space:]]+rowBackground\b' \
    'SidebarRow handleDrop')"
SIDEBAR_DROP_NORMALIZED="$(printf '%s' "$SIDEBAR_DROP_REGION" | normalize_swift)"
require_normalized_token "$SIDEBAR_DROP_NORMALIZED" 'state.moveItems(itemIDs, toFolderID: row.folder.id)' \
    "PromptStudioView folder drops must move all selected item IDs."

ORDERED_DRAG_IDS_REGION="$(extract_scoped_region "$APP_STATE_FILE" \
    '^[[:space:]]*func[[:space:]]+orderedItemIDsForDrag\b' \
    '^[[:space:]]*@discardableResult\b' \
    'AppState orderedItemIDsForDrag')"
ORDERED_DRAG_IDS_NORMALIZED="$(printf '%s' "$ORDERED_DRAG_IDS_REGION" | normalize_swift)"
require_normalized_pattern "$ORDERED_DRAG_IDS_NORMALIZED" \
    'func orderedItemIDsForDrag\(startingWith itemID: String\)[^{]*\{ .+ \}' \
    "AppState must provide a nonempty orderedItemIDsForDrag(startingWith itemID: String) body."

DELETE_SELECTION_MONITOR_REGION="$(extract_scoped_region "$PROMPT_STUDIO_VIEW_FILE" \
    '^[[:space:]]*((public|private|fileprivate|internal|open)[[:space:]]+)*(struct|final[[:space:]]+class|class)[[:space:]]+DeleteSelectionKeyMonitor\b' \
    '^[[:space:]]*((public|private|fileprivate|internal|open)[[:space:]]+)*(struct|final[[:space:]]+class|class)[[:space:]]+StandardTextEditingShortcutMonitor\b' \
    'DeleteSelectionKeyMonitor')"
DELETE_SELECTION_MONITOR_NORMALIZED="$(printf '%s' "$DELETE_SELECTION_MONITOR_REGION" | normalize_swift)"
require_normalized_token "$DELETE_SELECTION_MONITOR_NORMALIZED" 'guard !textInputActive,' \
    "Batch trash must not run while text input is active."
require_normalized_token "$DELETE_SELECTION_MONITOR_NORMALIZED" 'guard flags == .command' \
    "Batch trash must require Command-Delete with no additional modifiers."
require_normalized_token "$DELETE_SELECTION_MONITOR_NORMALIZED" 'return event.keyCode == 51 || event.keyCode == 117' \
    "Batch trash must handle both Delete and Forward Delete key codes."

echo "Native marquee multi-selection regression tests passed"
