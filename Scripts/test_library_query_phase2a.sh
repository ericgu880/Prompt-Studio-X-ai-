#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if grep -R -q 'LibraryQueryService\|LibraryItemSummary' "$ROOT/Sources/PromptStudio"; then
  echo "Phase 2A.1 must remain a shadow query and cannot replace the formal App UI data source" >&2
  exit 1
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/promptstudio-phase2a-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

python3 "$ROOT/Scripts/benchmark_library_query_phase2a.py" generate \
  --output-root "$WORK" \
  --sizes 301 601 \
  --seed 20260817

for size in 301 601; do
  db="$WORK/library-$size/database/promptstudio.sqlite"
  golden="$WORK/library-$size/golden-results.json"
  manifest="$WORK/library-$size/manifest.json"

  test -f "$db"
  test -f "$golden"
  test -f "$manifest"

  actual_count="$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM prompt_items;')"
  test "$actual_count" = "$size"
  test "$(sqlite3 -readonly "$db" 'PRAGMA integrity_check;')" = "ok"

  python3 - "$golden" "$size" <<'PY'
import json
import sys

path, expected_size = sys.argv[1], int(sys.argv[2])
payload = json.load(open(path, encoding="utf-8"))
required = {"all", "folder", "type", "model", "favorite", "recent", "trash", "combined"}
assert required.issubset(payload["queries"]), payload["queries"].keys()
assert payload["itemCount"] == expected_size
assert set(payload["parameters"]) == {"folderId", "modelId", "type"}
assert len(payload["queries"]["all"]["ids"]) == payload["queries"]["all"]["count"]
assert payload["ordering"]["default"] == ["sortOrder ASC", "createdAt DESC", "id ASC"]
assert payload["ordering"]["recent"] == ["lastUsedAt DESC", "createdAt DESC", "id ASC"]
PY
done

echo "Phase 2A fixture regression passed"
