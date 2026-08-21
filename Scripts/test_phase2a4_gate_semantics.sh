#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_BIN="${SWIFT_BIN:-/Users/guruocen/.swiftly/bin/swift}"

"$SWIFT_BIN" build --package-path "$ROOT" --product PromptStudioPhase2A4Benchmark >/dev/null
BIN="$ROOT/.build/arm64-apple-macosx/debug/PromptStudioPhase2A4Benchmark"
LOG=$(mktemp /private/tmp/phase2a4-gate-semantics.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

"$BIN" --gate-semantics-self-test >"$LOG" 2>&1
grep -q 'gate-semantics-self-test passed' "$LOG"
grep -q 'exact 9 shapes × 4 page sizes required' "$LOG"
grep -q 'malformed timing sets fail closed' "$LOG"
grep -q 'pageSize300 SQL/query over 50ms fails' "$LOG"
