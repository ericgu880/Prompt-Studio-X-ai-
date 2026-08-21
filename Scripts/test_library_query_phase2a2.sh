#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PERFORMANCE_ROOT="/Users/guruocen/Documents/PromptStudio Performance Fixtures"
FIXTURE_ROOT="$PERFORMANCE_ROOT/phase2a2-$(date +%Y%m%d-%H%M%S)"

case "$FIXTURE_ROOT" in
  *"PromptStudio Library"*) echo "refusing to write the real PromptStudio Library" >&2; exit 1 ;;
esac

python3 "$ROOT/Scripts/benchmark_library_query_phase2a2.py" generate \
  --output-root "$FIXTURE_ROOT" \
  --sizes 15959 50000 100000
python3 "$ROOT/Scripts/benchmark_library_query_phase2a2.py" benchmark \
  --output-root "$FIXTURE_ROOT" \
  --sizes 15959 50000 100000 \
  --repetitions 5

python3 - "$FIXTURE_ROOT" <<'PY'
import json
import pathlib
import sqlite3
import sys

root = pathlib.Path(sys.argv[1])
expected = {15959, 50000, 100000}
manifest = json.loads((root / "manifest.json").read_text())
assert set(manifest["sizes"]) == expected
report = json.loads((root / "benchmark-phase2a2.json").read_text())
assert {entry["itemCount"] for entry in report["results"]} == expected
for entry in report["results"]:
    assert entry["tagCount"] > 300
    assert entry["firstPage"]["p50Ms"] >= 0
    assert entry["firstPage"]["p95Ms"] >= entry["firstPage"]["p50Ms"]
    assert len(entry["tenPages"]["rowsPerRun"]) == 5
    assert any("SCAN prompt_item_tags" in line or "SCAN" in line for line in entry["explainBefore"])
    assert any("idx_phase2a2_prompt_item_tags_tag_order" in line for line in entry["explainAfter"])
    assert not any("TEMP B-TREE" in line.upper() for line in entry["explainAfter"])
    db_path = root / f"library-{entry['itemCount']}" / "database" / "promptstudio.sqlite"
    with sqlite3.connect(db_path) as db:
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        index_sql = db.execute(
            "SELECT sql FROM sqlite_master WHERE name = 'idx_phase2a2_prompt_item_tags_tag_order'"
        ).fetchone()[0]
        normalized_index_sql = " ".join(index_sql.split())
        assert "tagKey COLLATE BINARY, isFirstOccurrence, isDeleted, sortOrder ASC, createdAt DESC, promptItemId ASC" in normalized_index_sql
print(f"Phase 2A.2 benchmark passed: {root}")
PY
