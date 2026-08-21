#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_BIN="${SWIFT_BIN:-/Users/guruocen/.swiftly/bin/swift}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/promptstudio-phase2a-benchmark.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

"$SWIFT_BIN" run --package-path "$ROOT" PromptStudioLibraryQueryBenchmark --help \
  | grep -q 'Usage: PromptStudioLibraryQueryBenchmark'

grep -q 'PromptStudioLibraryQueryBenchmark' "$ROOT/Package.swift"
grep -q 'golden' "$ROOT/Sources/PromptStudioLibraryQueryBenchmark/main.swift"
grep -q 'EXPLAIN QUERY PLAN' "$ROOT/Sources/PromptStudioLibraryQueryBenchmark/main.swift"
grep -q 'preIndexExplain' "$ROOT/Sources/PromptStudioLibraryQueryBenchmark/main.swift"
grep -q 'postIndexCountExplain' "$ROOT/Sources/PromptStudioLibraryQueryBenchmark/main.swift"
if grep -q 'TimedDatabaseExecutor' "$ROOT/Sources/PromptStudioLibraryQueryBenchmark/main.swift"; then
  echo "Default benchmark must not run the pathological unindexed Summary suite" >&2
  exit 1
fi

python3 "$ROOT/Scripts/benchmark_library_query_phase2a.py" generate \
  --output-root "$TMP_ROOT" --sizes 301 601 --seed 20260817
"$SWIFT_BIN" run --package-path "$ROOT" PromptStudioLibraryQueryBenchmark \
  --fixture-root "$TMP_ROOT" \
  --fixtures library-301,library-601 \
  --output "$TMP_ROOT/report.json"
python3 - "$TMP_ROOT/report.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(report["fixtures"]) == {"library-301", "library-601"}
assert all(
    query["goldenMatch"]
    for fixture in report["fixtures"].values()
    for query in fixture["queries"].values()
)
PY

echo "Library query benchmark harness regression passed"
