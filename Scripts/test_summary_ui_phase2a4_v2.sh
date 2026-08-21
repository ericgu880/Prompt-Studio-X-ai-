#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/swift_toolchain.sh"

SUMMARY_COORDINATOR="$ROOT_DIR/Sources/PromptStudio/Views/SummaryMasonryCollectionView.swift"
SUMMARY_LIST="$ROOT_DIR/Sources/PromptStudio/Views/SummaryListView.swift"
SUMMARY_PROVIDER="$ROOT_DIR/Sources/PromptStudio/Views/SummaryProviderLoadState.swift"
SUMMARY_THUMBNAIL="$ROOT_DIR/Sources/PromptStudio/SharedThumbnailImageCache.swift"
SUMMARY_RENDERER_TEST="$ROOT_DIR/Tests/PromptStudioSummaryUITests/SummaryAttachedRendererTests.swift"
SUMMARY_EVENTS_TEST="$ROOT_DIR/Tests/PromptStudioSummaryUITests/SummaryCollectionCoordinatorTests.swift"
SUMMARY_PROVIDER_TEST="$ROOT_DIR/Tests/PromptStudioSummaryUITests/SummaryProviderLoadTests.swift"
SUMMARY_APPSTATE_TEST="$ROOT_DIR/Tests/PromptStudioSummaryUITests/SummaryAppStateIntegrationTests.swift"
SUMMARY_CORE_TEST="$ROOT_DIR/Tests/PromptStudioCoreTests/LibraryBrowserStateTests.swift"
SUMMARY_HOST="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

require_literal() {
    local file="$1"
    local literal="$2"
    local label="$3"
    if ! rg -Fq "$literal" "$file"; then
        echo "missing ${label}: ${literal}" >&2
        exit 1
    fi
}

require_literal "$SUMMARY_RENDERER_TEST" 'NSWindow(' 'attached NSWindow renderer test'
require_literal "$SUMMARY_RENDERER_TEST" 'NSScrollView(' 'attached NSScrollView renderer test'
require_literal "$SUMMARY_RENDERER_TEST" 'AttachedRecordingCollectionView' 'attached NSCollectionView recorder'
require_literal "$SUMMARY_RENDERER_TEST" 'insertedItemCount == 2_700' '2700 incremental inserts'
require_literal "$SUMMARY_RENDERER_TEST" 'reloadDataCount == 1' 'initial-only reloadData'
require_literal "$SUMMARY_RENDERER_TEST" 'rssPerPage' 'per-page RSS array'
require_literal "$SUMMARY_RENDERER_TEST" 'rssP50Bytes' 'RSS P50 metric'
require_literal "$SUMMARY_RENDERER_TEST" 'rssP95Bytes' 'RSS P95 metric'
require_literal "$SUMMARY_RENDERER_TEST" 'beginObservation()' 'monotonic renderer decode observation'
require_literal "$SUMMARY_APPSTATE_TEST" 'PROMPTSTUDIO_SUMMARY_UI_STARTUP_METRICS_PATH' 'startup metrics emission'
require_literal "$SUMMARY_RENDERER_TEST" 'PROMPTSTUDIO_SUMMARY_UI_DECODE_METRICS_PATH' 'decode metrics emission'
require_literal "$SUMMARY_COORDINATOR" 'func observeBounds(of scrollView: NSScrollView)' 'attached bounds observer'
require_literal "$SUMMARY_COORDINATOR" 'viewportChanged(visibleRect: clipView.bounds)' 'bounds-driven prefetch callback'
require_literal "$SUMMARY_COORDINATOR" 'let changedPaths = Set(existingContentChanges.compactMap(indexPath(for:)))' 'append targeted item/folder reload'
require_literal "$SUMMARY_COORDINATOR" 'let paths = Set(contentChanges.compactMap(indexPath(for:)))' 'targeted item/folder reload'
require_literal "$SUMMARY_COORDINATOR" 'restoreIncrementalSelection' 'symmetric-diff selection path'
require_literal "$SUMMARY_COORDINATOR" 'dragPasteboardItem(for id: String)' 'production multi-ID drag payload'
require_literal "$SUMMARY_EVENTS_TEST" 'hosted Summary card routes multi-ID item/folder drops' 'hosted event wrapper coverage'
require_literal "$SUMMARY_EVENTS_TEST" 'selectHistory == [Set([IndexPath(item: 1, section: 0)])]' 'non-vacuous incremental selection'
require_literal "$SUMMARY_PROVIDER" 'enum ProviderLoadState' 'provider load state machine'
require_literal "$SUMMARY_PROVIDER" 'try await Task.sleep(nanoseconds: nanoseconds)' 'bounded provider timeout'
require_literal "$SUMMARY_PROVIDER_TEST" 'valid PNG decode is generation-scoped' 'valid PNG cancellation test'
require_literal "$SUMMARY_THUMBNAIL" 'nonisolated static let decodeGate' 'deterministic thumbnail decode gate'
require_literal "$SUMMARY_CORE_TEST" 'summary paginator exposes retry phases' 'initial/replacement/append retry test'
require_literal "$SUMMARY_CORE_TEST" 'supported Summary filter provider failure retries the exact filter' 'supported-filter retry identity test'
require_literal "$SUMMARY_HOST" '@AppStorage("promptStudio.summary.legacyExplicitMode") private var legacySummarySurfaceEnabled = false' 'explicit legacy mode gate'
require_literal "$SUMMARY_LIST" 'SummaryProviderLoader.loadData' 'bounded SwiftUI provider drop path'

if rg -n 'PromptItem\(' "$SUMMARY_COORDINATOR" "$SUMMARY_LIST"; then
    echo 'Summary renderers must not decode full PromptItem values.' >&2
    exit 1
fi

SWIFT_EXEC="$(find_compatible_swift_tool swift "${SWIFT_EXEC:-}")"
METRICS_PATH="${TMPDIR:-/tmp}/summary-ui-phase2a4-v2-metrics-$$.json"
STARTUP_METRICS_PATH="${TMPDIR:-/tmp}/summary-ui-phase2a4-v2-startup-$$.json"
DECODE_METRICS_PATH="${TMPDIR:-/tmp}/summary-ui-phase2a4-v2-decode-$$.json"

"$SWIFT_EXEC" build --package-path "$ROOT_DIR" --target PromptStudio
PROMPTSTUDIO_SUMMARY_UI_METRICS_PATH="$METRICS_PATH" \
PROMPTSTUDIO_SUMMARY_UI_STARTUP_METRICS_PATH="$STARTUP_METRICS_PATH" \
PROMPTSTUDIO_SUMMARY_UI_DECODE_METRICS_PATH="$DECODE_METRICS_PATH" \
    "$SWIFT_EXEC" test --package-path "$ROOT_DIR" --filter PromptStudioSummaryUITests
"$SWIFT_EXEC" test --package-path "$ROOT_DIR" --filter PromptStudioCoreTests
"$SWIFT_EXEC" run --package-path "$ROOT_DIR" PromptStudioCoreUnitTests
"$ROOT_DIR/Scripts/test_masonry_layout_index.sh"

for run in 1 2 3; do
    echo "full SwiftPM suite run ${run}/3"
    "$SWIFT_EXEC" test --package-path "$ROOT_DIR"
done

if [[ ! -s "$METRICS_PATH" ]]; then
    echo "attached renderer did not emit metrics: $METRICS_PATH" >&2
    exit 1
fi
echo "attached renderer metrics: $METRICS_PATH"

if [[ ! -s "$STARTUP_METRICS_PATH" || ! -s "$DECODE_METRICS_PATH" ]]; then
    echo "Summary startup/decode metrics were not emitted" >&2
    exit 1
fi

python3 - "$METRICS_PATH" "$STARTUP_METRICS_PATH" "$DECODE_METRICS_PATH" <<'PY'
import json
import sys

aggregate_path, startup_path, decode_path = sys.argv[1:]

def load(path):
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise SystemExit(f"metrics must be a JSON object: {path}")
    return value

aggregate = load(aggregate_path)
startup = load(startup_path)
decode = load(decode_path)

aggregate_keys = {
    "rssPerPageBytes", "rssBeforeBytes", "rssPeakBytes", "rssDeltaBytes",
    "rssP50Bytes", "rssP95Bytes", "residentSummaries", "pageCalls", "maxInFlight",
}
if not aggregate_keys <= aggregate.keys():
    raise SystemExit(f"aggregate metrics missing keys: {sorted(aggregate_keys - aggregate.keys())}")
if not isinstance(aggregate["rssPerPageBytes"], list) or len(aggregate["rssPerPageBytes"]) != 10:
    raise SystemExit("aggregate RSS observation must contain ten page samples")
if aggregate["residentSummaries"] != 3000 or aggregate["pageCalls"] != 10 or aggregate["maxInFlight"] != 1:
    raise SystemExit(f"aggregate metrics do not match the attached ten-page fixture: {aggregate}")
if not all(type(value) is int and value >= 0 for value in aggregate["rssPerPageBytes"]):
    raise SystemExit("aggregate RSS samples must be non-negative integers")
if not all(type(aggregate[key]) is int and aggregate[key] >= 0 for key in aggregate_keys - {"rssPerPageBytes"}):
    raise SystemExit("aggregate scalar metrics must be non-negative integers")

startup_keys = {
    "normal_summary_full_item_decode", "normal_summary_legacy_boundary",
    "explicit_legacy_full_item_decode", "explicit_legacy_boundary",
}
if startup_keys != startup.keys():
    raise SystemExit(f"startup metrics keys changed: {sorted(startup.keys())}")
if not all(type(startup[key]) is int and startup[key] >= 0 for key in startup_keys):
    raise SystemExit("startup metrics must be observed non-negative integers")
if startup["normal_summary_full_item_decode"] != startup["normal_summary_legacy_boundary"]:
    raise SystemExit("normal startup observations diverged")
if startup["explicit_legacy_full_item_decode"] != startup["explicit_legacy_boundary"]:
    raise SystemExit("explicit legacy observations diverged")
if startup["normal_summary_full_item_decode"] != 0:
    raise SystemExit("normal Summary startup crossed the full-item boundary")
if startup["explicit_legacy_full_item_decode"] != 1:
    raise SystemExit("explicit legacy fixture did not add exactly one full-item load")

decode_keys = {"normal_summary_full_item_decode", "deliberate_legacy_item_control_decode"}
if decode_keys != decode.keys():
    raise SystemExit(f"decode metrics keys changed: {sorted(decode.keys())}")
if not all(type(decode[key]) is int and decode[key] >= 0 for key in decode_keys):
    raise SystemExit("decode metrics must be observed non-negative integers")
if decode["normal_summary_full_item_decode"] != 0 or decode["deliberate_legacy_item_control_decode"] != 1:
    raise SystemExit("renderer decode boundary observations are invalid")

print(f"validated aggregate/startup/decode metrics: {aggregate_path}, {startup_path}, {decode_path}")
PY

echo "Summary startup metrics: $STARTUP_METRICS_PATH"
echo "Summary decode metrics: $DECODE_METRICS_PATH"
echo 'Summary Phase 2A.4.2-2A.4.3 v2 validation passed.'
