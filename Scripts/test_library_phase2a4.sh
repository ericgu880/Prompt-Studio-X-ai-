#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_BIN="${SWIFT_BIN:-/Users/guruocen/.swiftly/bin/swift}"
PERFORMANCE_ROOT="/Users/guruocen/Documents/PromptStudio Performance Fixtures"
SOURCE_ROOT="${PHASE2A4_SOURCE_ROOT:-$PERFORMANCE_ROOT/phase2a1-20260817}"
RUN_ROOT="${PHASE2A4_OUTPUT_ROOT:-$PERFORMANCE_ROOT/phase2a4-1-smoke-$(date +%Y%m%d-%H%M%S)}"

test -x "$SWIFT_BIN"
REQUESTED_SCALES="${PHASE2A4_SCALES:-15959,50000,100000}"
IFS=',' read -r -a REQUESTED_SCALE_ARRAY <<< "$REQUESTED_SCALES"
previous_order=-1
validated_50000=0
for scale in "${REQUESTED_SCALE_ARRAY[@]}"; do
  case "$scale" in
    15959) current_order=0 ;;
    50000) current_order=1; validated_50000=1 ;;
    100000)
      if [[ "$validated_50000" != 1 ]]; then
        echo '100000 requires 50000 to be requested and preflight first' >&2
        exit 2
      fi
      current_order=2
      ;;
    *)
      echo "unsupported Phase 2A4.1 scale: $scale" >&2
      exit 2
      ;;
  esac
  if (( current_order <= previous_order )); then
    echo "Phase 2A4.1 scales must be requested once in ascending order: $REQUESTED_SCALES" >&2
    exit 2
  fi
  previous_order=$current_order
  test -f "$SOURCE_ROOT/library-$scale/database/promptstudio.sqlite"
done
grep -q 'PromptStudioPhase2A4Benchmark' "$ROOT/Package.swift"
grep -q 'legacyObservationClock' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'sourceTreeManifest' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'itemOrderHash' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'fullFieldOracleMode' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'browserState' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'idOnlyProductionQuery' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
! grep -q 'range(of: "FROM prompt_items p")' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'queryPageAndCountHook' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'connection.queryPageAndCount' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
! grep -q 'connection.query(pageSQL' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'pageUsesExpectedIndex' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'validatePageCountTimingContract' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'pageTagTempBTreeOnlyOrder' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
! grep -q '?? totalElapsed' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
! grep -q 'assert(self.pageStart == nil' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'writerPostWriteContract' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'migrationResumeOracle' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'processRestartProbe' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'validateRestartProbeChild' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'validateRestartProbeLexicalPaths' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'restartProbePhase2FileSystemCounter' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'phase2FileSystemCalls' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'ContinuousClock' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'observedExitWithinDeadline' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'forcedTimeoutProbe' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'phase2a4-test-mode' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
! grep -q 'let completedWithinDeadline = !process.isRunning' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'relationOrdinals' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'observedRelationTuples' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'probe-root' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'probe-token' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'parent-pid' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'pageAndCountCallCount' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'tagMutation' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'process restart probe timed out' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
! grep -q 'waitUntilExit' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'serviceFirstPageProbe' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'canonicalFramedManifest' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'atomicPageCountCancellation' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'countSQLiteStepHookObserved' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'lockContentionProbe' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'ordinaryObservedBusyCount' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'observedMaxMilliseconds' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
grep -q 'legacyObservationOrderMatchesRowID' "$ROOT/Sources/PromptStudioPhase2A4Benchmark/main.swift"
"$SWIFT_BIN" build --package-path "$ROOT" --product PromptStudioPhase2A4Benchmark
"$ROOT/Scripts/test_phase2a4_gate_semantics.sh"
test -x "$ROOT/Scripts/test_phase2a4_numeric_type_matrix.sh"

# C0 focused child safety regressions. These direct invocations use only
# rejected path strings or disposable sentinel fixtures; no real Library path
# reaches canonicalURL, SQLite, PromptRepository, or JSON output.
BENCHMARK_BIN="$ROOT/.build/arm64-apple-macosx/debug/PromptStudioPhase2A4Benchmark"
C0_SAFETY_ROOT=$(mktemp -d "$PERFORMANCE_ROOT/phase2a4-1-c0-safety.XXXXXX")
C0_TOKEN="00000000-0000-4000-8000-000000000001"
C0_SENTINEL="$C0_SAFETY_ROOT/sentinel.txt"
printf 'phase2a4-c0-sentinel\n' > "$C0_SENTINEL"
C0_SENTINEL_SHA_BEFORE=$(shasum -a 256 "$C0_SENTINEL" | awk '{print $1}')
C0_SENTINEL_MTIME_BEFORE=$(stat -f '%m' "$C0_SENTINEL")
mkdir -p "$RUN_ROOT"
run_restart_reject() {
  local label="$1" database="$2" output="$3" probe_root="$4" expected_phase2_calls="$5" log
  log=$(mktemp)
  if "$BENCHMARK_BIN" --restart-probe \
      --database "$database" --output "$output" --probe-root "$probe_root" \
      --probe-token "$C0_TOKEN" --parent-pid "$$" --folder c0-folder \
      --model c0-model --type image --tag c0-tag >"$log" 2>&1; then
    echo "restart-probe safety regression unexpectedly succeeded: $label" >&2
    cat "$log" >&2
    rm -f "$log"
    exit 1
  fi
  grep -q 'unsafe' "$log"
  grep -q "phase2FileSystemCalls=$expected_phase2_calls" "$log"
  test ! -e "$output"
  rm -f "$log"
}
C0_OUTSIDE="/private/tmp/phase2a4-c0-outside-$$.json"
run_restart_reject real-library \
  "/Users/guruocen/Documents/PromptStudio Library/database/promptstudio.sqlite" \
  "$C0_OUTSIDE" "$RUN_ROOT" 0
run_restart_reject source-fixture \
  "$SOURCE_ROOT/library-15959/database/promptstudio.sqlite" \
  "$C0_OUTSIDE" "$RUN_ROOT" 0
run_restart_reject outside-output \
  "$RUN_ROOT/stability-15959/database/promptstudio.sqlite" \
  "$C0_OUTSIDE" "$RUN_ROOT" 0
run_restart_reject traversal \
  "$RUN_ROOT/stability-15959/../bad/database/promptstudio.sqlite" \
  "$C0_OUTSIDE" "$RUN_ROOT" 0
C0_SYMLINK_ROOT="$C0_SAFETY_ROOT"
C0_MARKER="$C0_SYMLINK_ROOT/.phase2a4-restart-probe-$C0_TOKEN.marker"
printf '%s' "$C0_TOKEN" > "$C0_MARKER"
mkdir -p "$C0_SYMLINK_ROOT/stability-15959/database"
ln -s "$SOURCE_ROOT/library-15959/database/promptstudio.sqlite" "$C0_SYMLINK_ROOT/stability-15959/database/promptstudio.sqlite"
run_restart_reject symlink-database \
  "$C0_SYMLINK_ROOT/stability-15959/database/promptstudio.sqlite" \
  "$C0_SYMLINK_ROOT/stability-15959-process-restart.json" "$C0_SYMLINK_ROOT" 1
C0_SENTINEL_SHA_AFTER=$(shasum -a 256 "$C0_SENTINEL" | awk '{print $1}')
C0_SENTINEL_MTIME_AFTER=$(stat -f '%m' "$C0_SENTINEL")
test "$C0_SENTINEL_SHA_BEFORE" = "$C0_SENTINEL_SHA_AFTER"
test "$C0_SENTINEL_MTIME_BEFORE" = "$C0_SENTINEL_MTIME_AFTER"
rm -rf "$C0_SAFETY_ROOT"
echo 'restart-probe C0 safety regressions passed (real/source/outside/symlink rejected before repository I/O)'

# P0 path/symlink sentinel: overlap is rejected before clone or any source write.
SENTINEL="$PERFORMANCE_ROOT/phase2a4-1-safety-sentinel-$$"
SENTINEL_LOG=$(mktemp)
trap 'if [ -L "$SENTINEL" ]; then unlink "$SENTINEL"; fi; if [ -f "$SENTINEL_LOG" ]; then unlink "$SENTINEL_LOG"; fi' EXIT
ln -s "$SOURCE_ROOT" "$SENTINEL"
if "$SWIFT_BIN" run --package-path "$ROOT" PromptStudioPhase2A4Benchmark \
  --source-root "$SOURCE_ROOT" --output-root "$SENTINEL" --scales 15959 --iterations 30 --pages 1 >"$SENTINEL_LOG" 2>&1; then
  echo "unsafe overlap sentinel unexpectedly succeeded" >&2
  exit 1
fi
unlink "$SENTINEL"

# Closed WAL-header source smoke.  The copied source has no sidecars, so the
# benchmark must choose immutable URI mode and leave this tree unchanged.
WAL_ABSENT_ROOT="$PERFORMANCE_ROOT/phase2a1-review4-wal-absent-$(date +%Y%m%d-%H%M%S)"
WAL_ABSENT_RUN="$PERFORMANCE_ROOT/phase2a4-1-review4-wal-absent-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WAL_ABSENT_ROOT"
rsync -a --exclude='promptstudio.sqlite-wal' --exclude='promptstudio.sqlite-shm' "$SOURCE_ROOT/library-15959/" "$WAL_ABSENT_ROOT/library-15959/"
WAL_DB="$WAL_ABSENT_ROOT/library-15959/database/promptstudio.sqlite"
python3 - "$WAL_DB" <<'PY'
import sys
db=sys.argv[1]
with open(db,'rb') as f: header=f.read(20)
assert header[18:20] == bytes((2,2)), "fixture is not WAL-header"
assert not __import__('os').path.exists(db+'-wal') and not __import__('os').path.exists(db+'-shm')
PY
"$SWIFT_BIN" run --package-path "$ROOT" PromptStudioPhase2A4Benchmark \
  --source-root "$WAL_ABSENT_ROOT" --output-root "$WAL_ABSENT_RUN" \
  --scales 15959 --iterations 30 --pages 1 --page-sizes 300,301,600,601
python3 - "$WAL_ABSENT_RUN/phase2a4-1-report.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1],encoding='utf8'))
assert r['schema']=='phase2a4.1-item-sequence-benchmark-v1'
f=r['fixtures']['library-15959']
assert f['sourceSafety']['sourceOpenMode']=='immutable-uri'
assert f['sourceSafety']['sourceTreeSHAEqual'] is True
assert f['browserState']['available'] is False
PY

"$SWIFT_BIN" run --package-path "$ROOT" PromptStudioPhase2A4Benchmark \
  --source-root "$SOURCE_ROOT" --output-root "$RUN_ROOT" \
  --scales "$REQUESTED_SCALES" --iterations 30 --pages 10 --page-sizes 300,301,600,601

# The matrix aggregate launches bounded deterministic shards and verifies
# exact disjoint path coverage before emitting one durable JSON result.
PHASE2A4_MATRIX_AGGREGATE=1 PHASE2A4_MATRIX_AGGREGATE_SHARDS="${PHASE2A4_MATRIX_AGGREGATE_SHARDS:-16}" \
  "$ROOT/Scripts/test_phase2a4_numeric_type_matrix.sh" \
  "$RUN_ROOT/phase2a4-1-report.json" "$RUN_ROOT/phase2a4-1-manifest.json" \
  | tee "$RUN_ROOT/numeric-type-matrix.json"
if [[ "${PHASE2A4_SCHEMA_COMPATIBILITY:-0}" == "1" ]]; then
  # This read-only evidence check uses the separately pinned fixture paths.
  # Keep it opt-in so a fresh applied checkout has no runtime dependency on
  # prior review artifacts; the live gate uses embedded trusted schema data.
  "$ROOT/Scripts/test_phase2a4_schema_compatibility.sh" \
    | tee "$RUN_ROOT/schema-compatibility.json"
fi

PYTHONPATH="$ROOT/Scripts${PYTHONPATH:+:$PYTHONPATH}" python3 - "$RUN_ROOT/phase2a4-1-report.json" "$RUN_ROOT/phase2a4-1-manifest.json" <<'PY'
import json,sys,os
import phase2a4_numeric_validator as validator
report=json.load(open(sys.argv[1],encoding='utf8'))
manifest=json.load(open(sys.argv[2],encoding='utf8'))
documents=[('report',report),('benchmarkManifest',manifest)]
trusted=validator.load_trusted_family_schema()
schema=validator.build_schema(documents,trusted)
nullable_schema=validator.build_nullable_schema(documents)
coverage=validator.validate_documents(documents,schema,nullable_schema,trusted)
assert coverage['valid'],coverage['errors'][:5]
assert coverage['baselineNumericScalarLeaves']==coverage['visitedNumericScalarLeaves']==coverage['validatedNumericScalarLeaves']
assert coverage['missingNumericScalarLeaves']==coverage['unexpectedNumericScalarLeaves']==coverage['duplicateNumericScalarLeaves']==0
assert validator.nullable_number(None) and validator.nullable_number(0)
assert not validator.nullable_number(False) and not validator.nullable_number(True)
assert coverage['nullableNumericPaths']>0
print('numeric schema coverage baseline=validated',coverage['baselineNumericScalarLeaves'],'boolLeaves=',coverage['boolLeaves'],'nullableNumericPaths=',coverage['nullableNumericPaths'],'trustedFamilies=',len(trusted['families']),'trustedFingerprint=',trusted['fingerprint'],'validator=phase2a4_numeric_validator.validate_documents')

assert report['schema']=='phase2a4.1-item-sequence-benchmark-v1'
assert report['sourceSHAEqual'] is True
assert report['sqliteBusyCount']==report['sqliteLockedCount']==0
assert manifest['schema']=='phase2a4.1-manifest-v1'
assert manifest['onlineSQLiteBackupOnly'] is True and manifest['realLibraryAccessed'] is False
for name,f in report['fixtures'].items():
    safety=f['sourceSafety']
    assert safety['sourceTreeSHAEqual'] is True and safety['onlineBackupOnly'] is True
    assert safety['sourceTreeManifestMode']=='relative-path-sorted-length-framed-v1'
    assert safety['sourceTreeCanonicalRepeatEqual'] is True
    assert safety['realLibraryAccessed'] is False and safety['mediaReadCount']==safety['pathResolutionCount']==0
    m=f['itemSequenceMigration']
    assert m['phase']=='ready' and m['contiguous'] is True
    assert m['nullCount']==m['duplicateCount']==m['gapCount']==0
    assert f['artifactSHA256MatchesDisk'] is True
    assert f['legacyGolden']['oldLoaderUsed'] is True and f['legacyGolden']['clockExhausted'] is False
    assert f['legacyGolden']['legacyObservationOrderMatchesRowID'] is True
    assert f['summaryDetailParity']['pass'] is True
    assert f['runtimeSummaryDetailSample']['pass'] is True
    assert f['runtimeSummaryDetailSample']['runtimeProjectionObservedCount'] >= f['runtimeSummaryDetailSample']['summaryCheckedCount']
    assert 0.0 < f['runtimeSummaryDetailSample']['runtimeProjectionCoverage'] <= 1.0
    assert f['summaryValidation']['allCountsMatchGolden'] is True
    assert f['equalKeyOracle']['pass'] is True and f['timestampOracle']['pass'] is True
    assert f['stability']['pass'] is True and f['stability']['businessOrderHashesStable'] is True
    assert f['stability']['orderHashMode']=='builder-derived-id-only'
    assert f['migrationResume']['pass'] is True
    resume=f['migrationResume']
    oracle=resume['migrationResumeOracle']
    assert oracle['pass'] is True and oracle['rawBusinessFingerprintEqual'] is True
    assert oracle['fullShapeOrderPass'] is True
    assert oracle['timestampOracle']['pass'] is True and oracle['equalKeyOracle']['pass'] is True
    assert oracle['itemSequenceInvariants']['contiguous'] is True
    assert oracle['itemSequenceInvariants']['nullCount']==oracle['itemSequenceInvariants']['duplicateCount']==oracle['itemSequenceInvariants']['gapCount']==0
    assert resume['idempotentPass'] is True
    idem=resume['idempotentSecondRun']
    assert idem['completed'] is True and idem['rawBusinessFingerprintEqual'] is True
    assert idem['orderHashesEqual'] is True and idem['stateEqual'] is True
    assert f['cancellation']['pass'] is True
    cancel_probe=f['cancellation']['probe']
    assert cancel_probe['pass'] is True and cancel_probe['cancellationObserved'] is True
    assert cancel_probe['sqliteStepReached'] is True
    assert cancel_probe['queryStartHookObserved'] is True
    assert cancel_probe['pageCompleteHookObserved'] is True
    assert cancel_probe['countSQLiteStepHookObserved'] is True
    assert cancel_probe['activeAfterCancellation']==0 and cancel_probe['lateResultCount']==0
    assert cancel_probe['followupQueryPass'] is True
    coverage=f['busyLockedCoverage']
    assert coverage['pass'] is True and coverage['injectedCoverage'] is True
    assert coverage['ordinaryObservedZeroDistinct'] is True
    assert coverage['primaryCode'] in (5,6)
    assert coverage['codeName'] in ('SQLITE_BUSY','SQLITE_LOCKED')
    assert coverage['statement'].startswith('UPDATE prompt_items SET updatedAt = updatedAt')
    assert coverage['transaction']=='BEGIN IMMEDIATE;' and coverage['transactionRole']=='lock-holder'
    assert coverage['retryCount']==0 and coverage['retryHidden'] is False
    assert coverage['ordinaryObservedBusyCount']==0 and coverage['ordinaryObservedLockedCount']==0
    assert f['sqliteBusyCount']==f['sqliteLockedCount']==0
    assert f['fullTraversalCost']['count']==1
    assert f['fullSQLHashCost']['count']==1
    assert f['fullProjectionParity']['allShapesPass'] is True
    assert f['fullProjectionParity']['meta']['rawBusinessFingerprintEqual'] is True
    coverage=f['fullFieldCoverage']
    assert coverage['pass'] is True
    assert coverage['coverageCount']==coverage['expectedCoverageCount']
    assert coverage['coverageHashEqual'] is True
    assert coverage['missingCount']==coverage['unexpectedCount']==coverage['duplicateAcrossScopes']==0
    assert coverage['fullFieldOracleMode']=='persisted-table-and-version-scan'
    oracle=coverage['oracle']
    assert oracle['mode']=='persisted-table-and-version-scan'
    assert oracle['pass'] is True
    assert oracle['coverageCount']==oracle['expectedCoverageCount']
    assert oracle['missingCount']==oracle['unexpectedCount']==0
    assert oracle['fieldHashEqual'] is True
    assert all(v==0 for v in oracle['fieldMismatchCounts'].values())
    for full_hash in f['fullProjectionParity']['byShape'].values():
        assert full_hash['sqlMode']=='single-full-id-select'
        assert full_hash['pass'] is True and full_hash['hashEqual'] is True
        assert full_hash['rawBusinessFingerprintEqual'] is True
        assert full_hash['expectedCount']==full_hash['actualCount']==full_hash['totalCount']
        assert full_hash['projectionMode']=='idOrderOnly'
        assert full_hash['fieldParityCoveredBy']=='fullFieldOracle'
        assert full_hash['fullFieldOracleMode']=='persisted-table-and-version-scan'
    assert f['browserState']['available'] is False
    complete = f['completePagination']
    if name == 'library-15959':
        assert complete is True
    else:
        assert complete is False
        assert 'diagnostic deep traversal cost' in f['completePaginationReason']
    assert f['explainContract']['allShapesPass'] is True
    assert 'pageSQL is measured through SQLiteReadConnection' in report.get('timingSemantics', '')
    for shape,explain in f['explainContract']['byShape'].items():
        assert explain['pageUsesExpectedIndex'] is True
        assert explain['countUsesExpectedIndex'] is True
        assert explain['usesExpectedIndex'] is True
        assert explain['pageUsesTagRelationIndex'] is True
        assert explain['countUsesTagRelationIndex'] is True
        assert explain['usesTagRelationIndex'] is True
        assert explain['pageUsesTagPromptItemLookup'] is True
        assert explain['countUsesTagPromptItemLookup'] is True
        assert explain['usesTagPromptItemLookup'] is True
        assert explain['pageNoPromptVersionScan'] is True
        assert explain['countNoPromptVersionScan'] is True
        if shape == 'Tag':
            assert explain['pageAllowsExpectedTagTempBTree'] is True
            assert explain['pageTagTempBTreeOnlyOrder'] is True
            assert all(detail.strip().upper() == 'USE TEMP B-TREE FOR ORDER BY' for detail in explain['pageTagTempBTreeDetails'])
            assert explain['countNoTempBTree'] is True
        else:
            assert explain['pageNoTempBTree'] is True
            assert explain['countNoTempBTree'] is True
            assert explain['noTempBTree'] is True
    for shape,runs in f['itemOrderParity']['byShape'].items():
        assert set(runs)=={'300','301','600','601'}, (name,shape,runs.keys())
        for page_size,run in runs.items():
            assert run['pass'] is True and run['hashEqual'] is True
            assert run['expectedCount']==run['actualCount']
            assert run['observedPrefixCount']==run['uniqueCount']
            assert run['duplicateCount']==run['missingCount']==run['unexpectedCount']==run['orderMismatchCount']==0
            assert run['totalCountMismatch'] is False
            if complete and run.get('fullTraversal') is True:
                assert page_size=='300'
                assert run['observedPrefixCount']==run['expectedCount']
                assert run['terminalPage'] is True
                assert run['hashScope']=='full'
            else:
                assert run.get('boundaryOnly') is True
                assert run['hashScope']=='observedPrefix'
                if run['expectedCount']>int(page_size):
                    assert run['pagesFetched']>=2
                    assert run['crossBoundary'] is True
    for run in f['tenPageRun']['byShape'].values():
        if not run['shortResult']:
            assert run['requestedPages']==run['pagesFetched']==10
    for shape, timing in f['timings'].items():
        assert set(f['timings'])=={'All','Folder','Tag','Type','Model','Favorite','Recent','Trash','Combined'}
        assert set(timing['byPageSize'])=={'300','301','600','601'}
        for page_size in ('300','301','600','601'):
            assert set(timing['byPageSize'][page_size])=={'sql','pageSQL','countSQL','decode','total'}
            for stage in ('sql','pageSQL','countSQL','decode','total'):
                metric=timing['byPageSize'][page_size][stage]
                assert metric['count']==30
                assert metric['maxMilliseconds']>=metric['p95Milliseconds']>=metric['p50Milliseconds']
    assert f['costs']['writer']['pass'] is True
    writer=f['costs']['writer']
    contract=writer['writerPostWriteContract']
    assert contract['pass'] is True and contract['nonTargetFingerprintEqual'] is True
    tag_mutation=writer['tagMutation']
    assert tag_mutation['pass'] is True and tag_mutation['changed'] is True
    assert tag_mutation['before'] != tag_mutation['after']
    assert tag_mutation['relationTags']==tag_mutation['after']
    assert len(tag_mutation['relationKeys'])==len(tag_mutation['after'])
    assert tag_mutation['relationOrdinals']==tag_mutation['expectedRelationOrdinals']
    assert tag_mutation['relationFirstOccurrence']==tag_mutation['expectedRelationFirstOccurrence']
    assert tag_mutation['relationDeleted']==tag_mutation['expectedRelationDeleted']
    tuples=tag_mutation['observedRelationTuples']
    assert [row['ordinal'] for row in tuples]==tag_mutation['relationOrdinals']
    assert [row['tagName'] for row in tuples]==tag_mutation['relationTags']
    assert [row['tagKey'] for row in tuples]==tag_mutation['relationKeys']
    assert [row['isFirstOccurrence'] for row in tuples]==tag_mutation['relationFirstOccurrence']
    assert [row['isDeleted'] for row in tuples]==tag_mutation['relationDeleted']
    assert contract['batchInputOrder']==contract['batchDurableOrder']
    assert contract['batchItemSequenceOrderPass'] is True
    seq=contract['batchItemSequence']
    assert len(seq)==len(contract['batchInputOrder']) and all(a < b for a,b in zip(seq,seq[1:]))
    assert contract['concurrentRecordsPass'] is True
    assert {row['id'] for row in contract['concurrentRecords']} == {'phase2a4-writer-concurrent-0','phase2a4-writer-concurrent-1'}
    assert contract['postDeleteExpectedGap'] is True and contract['postDeleteGapPass'] is True
    assert contract['postDeleteMissingSequences']==[contract['postDeleteDeletedSequence']]
    post=contract['postDeleteInvariants']
    assert post['contiguous'] is False and post['nullCount']==post['duplicateCount']==0 and post['gapCount']==1
    batch_inv=writer['batchSequenceInvariants']
    assert batch_inv['contiguous'] is True
    assert batch_inv['nullCount']==batch_inv['duplicateCount']==batch_inv['gapCount']==0
    for stage_name,stage in writer['stages'].items():
        assert stage['errors']==0 and stage.get('count',0)>0
    full_target=f['fullTotalTarget']
    assert full_target['metric']=='max-shape pageSize=300 SQL P95 gate'
    assert full_target['maxMetric']=='max-shape total maxMilliseconds (all page sizes, report-only)'
    assert full_target['timingSetValid'] is True
    assert full_target['p95GatePass'] is True
    page300_sql_p95=[]
    all_total_p95=[]
    all_max=[]
    for shape in f['timings'].values():
        page300_sql_p95.append(shape['byPageSize']['300']['sql']['p95Milliseconds'])
        for page in shape['byPageSize'].values():
            all_total_p95.append(page['total']['p95Milliseconds'])
            all_max.append(page['total']['maxMilliseconds'])
    assert len(page300_sql_p95)==9 and full_target['observedPage300SQLP95Milliseconds']==max(page300_sql_p95)
    assert len(all_total_p95)==36 and full_target['observedP95TotalMilliseconds']==max(all_total_p95)
    assert all_max and full_target['observedMaxMilliseconds']==max(all_max)
    assert full_target['observedMaxTotalMilliseconds']==max(all_max)
    stability=f['stability']
    assert stability['freshHandleReopen']
    assert stability['afterProcessRestart']['processRestartProbe']['freshProcess'] is True
    assert stability['afterProcessRestart']['processRestartProbe']['pass'] is True
    restart_probe=stability['afterProcessRestart']['processRestartProbe']
    assert restart_probe['processIdentifier']>0 and restart_probe['parentProcessIdentifier']>0
    assert restart_probe['processIdentifier'] != restart_probe['parentProcessIdentifier']
    timeout_probe=stability['processRestartProbe']
    assert timeout_probe['timeoutBounded'] is True
    assert timeout_probe['timeoutSeconds']==15
    assert timeout_probe['timeoutOutcome']=='natural-exit-within-deadline'
    assert timeout_probe['timedOut'] is False
    assert timeout_probe['observedExit'] is True and timeout_probe['observedExitWithinDeadline'] is True
    assert timeout_probe['elapsedMilliseconds'] <= timeout_probe['boundedElapsedMilliseconds']
    forced=stability['forcedTimeoutProbe']
    assert forced['timedOut'] is True and forced['timeoutMilliseconds']==100
    assert forced['observedExitWithinDeadline'] is False
    assert forced['timeoutOutcome'] in ('timed-out-terminated','timed-out-killed')
    assert forced['terminateSent'] is True or forced['killSent'] is True
    assert forced['childResidual'] is False
    assert forced['elapsedMilliseconds'] <= forced['boundedElapsedMilliseconds']
    assert stability['serviceFirstPageStable'] is True
    child_page=stability['serviceFirstPageAfterProcessRestart']
    before_page=stability['serviceFirstPageBefore']
    assert child_page['pass'] is True and child_page['count']==before_page['count'] and child_page['firstIDs']==before_page['firstIDs']
    assert child_page['atomicPageAndCount'] is True and child_page['atomicPageAndCountCalls']==1
    assert child_page['serviceRebuilt'] is True
print('Phase 2A4.1 C1-C10 acceptance smoke passed:',sys.argv[1])
PY
