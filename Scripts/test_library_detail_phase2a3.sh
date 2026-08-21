#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PERFORMANCE_ROOT="/Users/guruocen/Documents/PromptStudio Performance Fixtures"
SWIFT_BIN="${SWIFT_BIN:-/Users/guruocen/.swiftly/bin/swift}"
FIXTURE_ROOT="$(mktemp -d "$PERFORMANCE_ROOT/phase2a3-test.XXXXXX")"
REPORT="$FIXTURE_ROOT/benchmark-report.json"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

case "$FIXTURE_ROOT" in
  *"PromptStudio Library"*) echo "refusing to write the real PromptStudio Library" >&2; exit 1 ;;
esac

python3 -m py_compile "$ROOT/Scripts/benchmark_library_detail_phase2a3.py"

if [[ "${PHASE2A3_QUICK:-0}" == "1" ]]; then
  python3 "$ROOT/Scripts/benchmark_library_detail_phase2a3.py" generate \
    --output-root "$FIXTURE_ROOT" --versions 1 --references 0 --replicas 8 --no-scales
else
  python3 "$ROOT/Scripts/benchmark_library_detail_phase2a3.py" generate \
    --output-root "$FIXTURE_ROOT"
fi
python3 "$ROOT/Scripts/benchmark_library_detail_phase2a3.py" validate --output-root "$FIXTURE_ROOT"

"$SWIFT_BIN" build --package-path "$ROOT" --product PromptStudioLibraryDetailBenchmark
BENCHMARK_ARGS=(
  --fixture-root "$FIXTURE_ROOT"
  --output "$REPORT"
  --samples 100
  --cache-hits 1000
  --rapid-rounds 20
  --rapid-selections 50
)
if [[ "${PHASE2A3_QUICK:-0}" == "1" ]]; then
  BENCHMARK_ARGS+=(--fixtures matrix/versions-1/refs-0/replica-00 --no-scales)
else
  BENCHMARK_ARGS+=(--include-giant)
fi
"$SWIFT_BIN" run --package-path "$ROOT" PromptStudioLibraryDetailBenchmark \
  "${BENCHMARK_ARGS[@]}"

python3 - "$FIXTURE_ROOT" "$REPORT" <<'PY'
import json
import os
import pathlib
import sqlite3
import sys

root = pathlib.Path(sys.argv[1])
report = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
matrix = manifest["matrix"]
quick = os.environ.get("PHASE2A3_QUICK") == "1"
assert set(matrix["versions"]) == ({1} if len(matrix["versions"]) == 1 else {1, 10, 100, 500})
assert set(matrix["references"]) == ({0} if len(matrix["references"]) == 1 else {0, 1, 20, 100})
assert matrix["replicas"] >= 8
assert matrix["selectionIDsPerFixture"] == 32
assert manifest["syntheticMatrixPathsAreFixtureURLs"] is True
assert manifest["scalePathsAreOpaque"] is True
assert manifest["mediaPathsResolvedOrOpened"] is False
assert report["schema"] == "phase2a3-detail-benchmark"
assert report["integrity"]["syntheticMatrixPathsAreFixtureURLs"] is True
assert report["integrity"]["scalePathsAreOpaque"] is True
assert report["integrity"]["mediaPathsResolvedOrOpened"] is False
assert not any(key.endswith("GeneratedFixturesUseFixturePaths") for key in report["integrity"])
if quick:
    assert len(report["fixtures"]) == 1
    assert report["realScaleDetails"] == []
else:
    assert len(report["fixtures"]) == 17
    assert len(report["realScaleDetails"]) == 3
    expected_cardinalities = {
        (versions, references)
        for versions in (1, 10, 100, 500)
        for references in (0, 1, 20, 100)
    }
    actual_cardinalities = {
        (fixture["cardinality"]["versions"], fixture["cardinality"]["references"])
        for fixture in report["fixtures"]
        if fixture["sourceKind"] == "synthetic-matrix"
    }
    assert actual_cardinalities == expected_cardinalities
    assert report["fixtures"][-1]["sourceKind"] == "synthetic-matrix"
    assert report["fixtures"][-1]["path"].startswith("giant/")
assert report["fixtures"]
fixture = report["fixtures"][0]
cold = fixture["cold"]
for section in ("sql", "decode", "total"):
    if section == "total":
        assert cold[section]["count"] >= 100
        assert cold[section]["maxMilliseconds"] >= cold[section]["p95Milliseconds"] >= cold[section]["p50Milliseconds"]
    else:
        assert cold[section] is None
assert cold["sqlDecodeSupport"]["supported"] is False
assert fixture["cache"]["hits"] >= 1000
assert fixture["cache"]["sqlCalls"] == 0
assert fixture["rapidSelection"]["rounds"] >= 20
assert fixture["rapidSelection"]["selectionsPerRound"] >= 50
assert len(fixture["rapidSelection"]["runs"]) == fixture["rapidSelection"]["rounds"]
assert all(run["selectedCount"] == 50 for run in fixture["rapidSelection"]["runs"])
assert fixture["rapidSelection"]["noBacklog"]
assert fixture["cache"]["countBound"]["evictions"] >= 1
assert fixture["cache"]["oversize"]["rejected"]
golden = root / "matrix" / "versions-1" / "refs-0" / "replica-00" / "golden-results.json"
golden_text = golden.read_text(encoding="utf-8")
assert "fixture://prompt" not in golden_text
assert len(json.loads(golden_text)["selectionIDs"]) == 32
with sqlite3.connect(root / "matrix" / "versions-1" / "refs-0" / "replica-00" / "database" / "promptstudio.sqlite") as db:
    assert db.execute("PRAGMA integrity_check;").fetchone()[0] == "ok"
    assert not db.execute("PRAGMA foreign_key_check;").fetchall()
    assert db.execute("SELECT COUNT(*) FROM prompt_items;").fetchone()[0] == 32
for entry in manifest.get("scales", []):
    assert entry["sourceUnchanged"]
    assert entry["sourceSHA256Before"] == entry["sourceSHA256After"]
    with sqlite3.connect(f"file:{entry['database']}?mode=ro", uri=True) as db:
        assert db.execute("PRAGMA journal_mode;").fetchone()[0].lower() == "delete"
        for asset_path, thumbnail_path, references_json in db.execute(
            "SELECT assetPath, thumbnailPath, referencesJSON FROM prompt_items;"
        ):
            for path in (asset_path, thumbnail_path):
                if path:
                    assert path.startswith("fixture://opaque-scale/")
            for reference in json.loads(references_json or "[]"):
                if reference.get("path"):
                    assert reference["path"].startswith("fixture://opaque-scale/")
assert all(item["sourceUnchanged"] for item in report["summaryScales"])
for scale in report["summaryScales"]:
    detail = scale["detail"]
    assert detail["cold"]["total"]["count"] >= 100
    assert detail["cache"]["hits"] >= 1000 and detail["cache"]["sqlCalls"] == 0
    assert detail["cache"]["unique32"]["count"] == 32
    assert detail["cache"]["unique32"]["rssPeakBytes"] >= detail["cache"]["unique32"]["rssBeforeBytes"]
    assert detail["rapidSelection"]["rounds"] == 20
    assert detail["rapidSelection"]["selectionsPerRound"] == 50
print("Phase 2A.3 detail benchmark harness passed")
PY

"$ROOT/Scripts/test_library_detail_phase2a3_static.sh"
