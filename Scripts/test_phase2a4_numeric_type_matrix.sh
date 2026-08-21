#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_PATH=${1:?usage: test_phase2a4_numeric_type_matrix.sh REPORT MANIFEST}
MANIFEST_PATH=${2:?usage: test_phase2a4_numeric_type_matrix.sh REPORT MANIFEST}
SHARD_INDEX=${PHASE2A4_MATRIX_SHARD_INDEX:-0}
SHARD_COUNT=${PHASE2A4_MATRIX_SHARD_COUNT:-1}
if ! [[ "$SHARD_INDEX" =~ ^[0-9]+$ && "$SHARD_COUNT" =~ ^[1-9][0-9]*$ && "$SHARD_INDEX" -lt "$SHARD_COUNT" ]]; then
    echo "invalid matrix shard: index=$SHARD_INDEX count=$SHARD_COUNT" >&2
    exit 2
fi

# The production command uses this bounded aggregate mode.  Each child is a
# normal matrix invocation with a deterministic disjoint shard; the aggregate
# verifies exact path coverage and SHA-256 unions before emitting one report.
if [[ "${PHASE2A4_MATRIX_AGGREGATE:-0}" == "1" ]]; then
    AGGREGATE_SHARDS=${PHASE2A4_MATRIX_AGGREGATE_SHARDS:-16}
    if ! [[ "$AGGREGATE_SHARDS" =~ ^[1-9][0-9]*$ ]]; then
        echo "invalid aggregate shard count: $AGGREGATE_SHARDS" >&2
        exit 2
    fi
    AGGREGATE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/phase2a4-matrix-aggregate.XXXXXX")
    AGGREGATE_STATUS=0
    AGGREGATE_CONCURRENCY=${PHASE2A4_MATRIX_AGGREGATE_CONCURRENCY:-4}
    if ! [[ "$AGGREGATE_CONCURRENCY" =~ ^[1-9][0-9]*$ ]]; then
        echo "invalid aggregate concurrency: $AGGREGATE_CONCURRENCY" >&2
        rm -rf "$AGGREGATE_ROOT"
        exit 2
    fi
    for ((aggregate_batch_start = 0; aggregate_batch_start < AGGREGATE_SHARDS; aggregate_batch_start += AGGREGATE_CONCURRENCY)); do
        AGGREGATE_PIDS=()
        for ((aggregate_index = aggregate_batch_start; aggregate_index < AGGREGATE_SHARDS && aggregate_index < aggregate_batch_start + AGGREGATE_CONCURRENCY; aggregate_index++)); do
            (
                PHASE2A4_MATRIX_AGGREGATE=0 \
                PHASE2A4_MATRIX_SHARD_INDEX="$aggregate_index" \
                PHASE2A4_MATRIX_SHARD_COUNT="$AGGREGATE_SHARDS" \
                "$0" "$REPORT_PATH" "$MANIFEST_PATH" \
                    >"$AGGREGATE_ROOT/$aggregate_index.json" \
                    2>"$AGGREGATE_ROOT/$aggregate_index.stderr"
            ) &
            AGGREGATE_PIDS+=("$!")
        done
        for aggregate_pid in "${AGGREGATE_PIDS[@]}"; do
            if ! wait "$aggregate_pid"; then
                AGGREGATE_STATUS=1
            fi
        done
        if (( AGGREGATE_STATUS != 0 )); then
            break
        fi
    done
    if (( AGGREGATE_STATUS != 0 )); then
        for aggregate_stderr in "$AGGREGATE_ROOT"/*.stderr; do
            if [[ -s "$aggregate_stderr" ]]; then
                cat "$aggregate_stderr" >&2
            fi
        done
        rm -rf "$AGGREGATE_ROOT"
        exit 1
    fi
    PYTHONPATH="$ROOT/Scripts${PYTHONPATH:+:$PYTHONPATH}" python3 - "$AGGREGATE_ROOT" "$AGGREGATE_SHARDS" "$REPORT_PATH" "$MANIFEST_PATH" <<'AGGREGATE_PY'
import copy
import hashlib
import json
import os
import sys

import phase2a4_numeric_validator as validator

aggregate_root, shard_count_text, report_path, manifest_path = sys.argv[1:]
shard_count = int(shard_count_text)
shards = []
for index in range(shard_count):
    with open(os.path.join(aggregate_root, f"{index}.json"), encoding="utf-8") as handle:
        payload = json.load(handle)
    assert payload["shard"]["index"] == index, payload["shard"]
    assert payload["shard"]["count"] == shard_count, payload["shard"]
    shards.append(payload)

base = shards[0]
for payload in shards[1:]:
    for field in ("matrixMode", "requestedScales", "authoritativeMatrix", "trustedContainerContractScope"):
        assert payload[field] == base[field], (field, payload[field], base[field])

with open(report_path, encoding="utf-8") as handle:
    report = json.load(handle)
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
documents = [("report", report), ("benchmarkManifest", manifest)]
trusted = validator.load_trusted_family_schema()
schema = validator.build_schema(documents, trusted)
nullable_schema = validator.build_nullable_schema(documents)
all_numeric = sorted(
    ((label, path) for label, path, _ in schema),
    key=lambda target: (target[0], repr(target[1])),
)
all_nullable = sorted(
    ((label, path) for label, path, _ in nullable_schema),
    key=lambda target: (target[0], repr(target[1])),
)
all_containers = sorted(
    (
        (label, path)
        for label, document in documents
        for path, _ in validator.container_occurrences(document)
    ),
    key=lambda target: (target[0], repr(target[1])),
)
baseline_container_index = validator.build_container_validation_index(documents)
if base["authoritativeMatrix"]:
    container_index = validator.build_trusted_container_validation_index(("library-15959",))
    assert set(baseline_container_index) == set(container_index)
else:
    container_index = baseline_container_index


def records_for(targets):
    return [{"label": label, "path": list(path)} for label, path in targets]


def record_key(record):
    return record["label"], repr(tuple(record["path"]))


def canonical_records(records):
    return sorted(records, key=record_key)


def records_hash(records):
    payload = json.dumps(canonical_records(records), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def assert_sharded_records(field, targets, subkey=None, shard_source_targets=None):
    expected = records_for(targets)
    expected_set = {(record["label"], tuple(record["path"])) for record in expected}
    shard_source_targets = targets if shard_source_targets is None else shard_source_targets
    target_set = set(targets)
    observed = []
    per_shard = []
    for index, payload in enumerate(shards):
        records = payload["schemaCoverage"][field]
        if subkey is not None:
            records = records[subkey]
        expected_records = records_for(
            target
            for position, target in enumerate(shard_source_targets)
            if position % shard_count == index and target in target_set
        )
        assert records == expected_records, (field, index, len(records), len(expected_records))
        keys = {(record["label"], tuple(record["path"])) for record in records}
        assert len(keys) == len(records), (field, index)
        per_shard.append({"count": len(records), "sha256": records_hash(records)})
        observed.extend(records)
    observed_keys = {(record["label"], tuple(record["path"])) for record in observed}
    assert observed_keys == expected_set, (field, len(observed_keys), len(expected_set))
    assert len(observed) == len(expected), (field, len(observed), len(expected))
    return {"count": len(expected), "sha256": records_hash(expected), "shards": per_shard}


numeric_path_coverage = {}
for mutation_name in ("false", "true", "string", "NaN"):
    numeric_path_coverage[mutation_name] = assert_sharded_records(
        "numericLeafMutationPathListsByKind", all_numeric, mutation_name
    )
    for index, payload in enumerate(shards):
        assert payload["schemaCoverage"]["numericLeafMutationPathsPerKind"][mutation_name] == payload["shard"]["numericTargets"]

container_path_coverage = assert_sharded_records("containerMutationPaths", all_containers)
container_kind_path_coverage = {}
for mutation_name in ("missing", "extra", "wrongType", "duplicate"):
    if mutation_name == "duplicate":
        mutation_targets = [
            target for target in all_containers
            if container_index[target]["kind"] == "list"
        ]
    else:
        mutation_targets = all_containers
    container_kind_path_coverage[mutation_name] = assert_sharded_records(
        "containerMutationPathsByKind", mutation_targets, mutation_name, all_containers
    )

nullable_path_coverage = {}
for mutation_name in ("false", "true", "string", "NaN"):
    nullable_path_coverage[mutation_name] = assert_sharded_records(
        "nullableInvalidPathListsByKind", all_nullable, mutation_name
    )

expected_container_checks = {
    "missing": len(all_containers),
    "extra": len(all_containers),
    "wrongType": len(all_containers),
    "duplicate": sum(1 for target in all_containers if container_index[target]["kind"] == "list"),
}
numeric_checks = sum(payload["schemaCoverage"]["numericLeafMutationChecks"] for payload in shards)
assert numeric_checks == len(all_numeric) * 4
container_checks = {
    kind: sum(payload["schemaCoverage"]["containerMutationChecksByKind"][kind] for payload in shards)
    for kind in expected_container_checks
}
assert container_checks == expected_container_checks
nullable_checks = sum(payload["schemaCoverage"]["nullableInvalidChecks"] for payload in shards)
assert nullable_checks == len(all_nullable) * 4
nullable_acceptance = {
    kind: sum(payload["schemaCoverage"]["nullableAcceptanceChecksByKind"][kind] for payload in shards)
    for kind in ("None", "zero")
}
assert nullable_acceptance == {"None": len(all_nullable), "zero": len(all_nullable)}

coverage = copy.deepcopy(base["schemaCoverage"])
coverage["numericLeafMutationChecks"] = numeric_checks
coverage["numericLeafPathChecks"] = numeric_checks
coverage["numericLeafMutationPathsPerKind"] = {
    kind: details["count"] for kind, details in numeric_path_coverage.items()
}
coverage["numericLeafMutationPathSHA256ByKind"] = numeric_path_coverage
coverage["numericLeafRestoreChecks"] = numeric_checks
coverage["containerMutationTargets"] = len(all_containers)
coverage["containerOccurrenceCount"] = len(all_containers)
coverage["containerMutationPaths"] = records_for(all_containers)
coverage["containerMutationChecks"] = sum(container_checks.values())
coverage["containerMutationChecksByKind"] = container_checks
coverage["containerMutationPathSHA256"] = container_path_coverage
coverage["containerMutationPathSHA256ByKind"] = container_kind_path_coverage
coverage["containerRestoreChecks"] = sum(container_checks.values())
coverage["containerDuplicateNotApplicable"] = sum(
    1 for target in all_containers if container_index[target]["kind"] == "dict"
)
coverage["containerDuplicateApplicable"] = expected_container_checks["duplicate"]
coverage["nullableNoneAccepted"] = len(all_nullable)
coverage["nullableZeroAccepted"] = len(all_nullable)
coverage["nullableAcceptanceChecksByKind"] = nullable_acceptance
coverage["nullableAcceptanceChecks"] = sum(nullable_acceptance.values())
coverage["nullableInvalidChecks"] = nullable_checks
coverage["nullableInvalidPathsPerKind"] = {
    kind: details["count"] for kind, details in nullable_path_coverage.items()
}
coverage["nullableInvalidPathSHA256ByKind"] = nullable_path_coverage
coverage["nullableRestoreChecks"] = sum(nullable_acceptance.values()) + nullable_checks
coverage["allBaselineNumericPathsRejected"] = all(
    count == len(all_numeric) for count in coverage["numericLeafMutationPathsPerKind"].values()
)
coverage["allNullableInvalidPathsRejected"] = True

aggregate = copy.deepcopy(base)
aggregate.pop("shard", None)
for shard_only_field in (
    "numericLeafMutationPathListsByKind",
    "containerMutationPathsByKind",
    "nullableInvalidPathListsByKind",
):
    coverage.pop(shard_only_field, None)
aggregate["aggregateShardSummary"] = {
    "shardCount": shard_count,
    "numericTargetsTotal": len(all_numeric),
    "containerTargetsTotal": len(all_containers),
    "nullableTargetsTotal": len(all_nullable),
    "boundedConcurrency": int(os.environ.get("PHASE2A4_MATRIX_AGGREGATE_CONCURRENCY", "4")),
}
aggregate["aggregate"] = {
    "shardCount": shard_count,
    "exactDisjointPathCoverage": True,
    "numericLeafPathSHA256ByKind": numeric_path_coverage,
    "containerPathSHA256": container_path_coverage,
    "containerPathSHA256ByKind": container_kind_path_coverage,
    "nullableInvalidPathSHA256ByKind": nullable_path_coverage,
}
aggregate["schemaCoverage"] = coverage
print(json.dumps(aggregate, sort_keys=True))
AGGREGATE_PY
    AGGREGATE_STATUS=$?
    rm -rf "$AGGREGATE_ROOT"
    exit "$AGGREGATE_STATUS"
fi

PYTHONPATH="$ROOT/Scripts${PYTHONPATH:+:$PYTHONPATH}" python3 - "$REPORT_PATH" "$MANIFEST_PATH" "$SHARD_INDEX" "$SHARD_COUNT" <<'PY'
import copy
import json
import sys

import phase2a4_numeric_validator as validator

report_path, manifest_path = sys.argv[1:3]
shard_index = int(sys.argv[3])
shard_count = int(sys.argv[4])
with open(report_path, encoding="utf-8") as handle:
    report = json.load(handle)
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

baseline_documents = [("report", report), ("benchmarkManifest", manifest)]
trusted = validator.load_trusted_family_schema()
schema = validator.build_schema(baseline_documents, trusted)
nullable_schema = validator.build_nullable_schema(baseline_documents)
path_index = validator.compile_validation_index(schema, nullable_schema)
baseline_container_index = validator.build_container_validation_index(baseline_documents)
requested_scales = manifest.get("scales", [])
authoritative_matrix = requested_scales == [15959] and "library-15959" in report.get("fixtures", {})

# The exhaustive static container contract is intentionally limited to the
# pinned 15959 authority.  A post-benchmark report may contain only 50k/100k
# fixture scopes; its live acceptance must not require a 15959 occurrence set
# or rebuild a contract from the document under test.  The baseline-derived
# index below is retained only as a mutation census/type lookup for dynamic
# reports.  Every live C2 mutation still calls validate_documents with no
# container_schema.
container_index = (
    validator.build_trusted_container_validation_index(("library-15959",))
    if authoritative_matrix
    else baseline_container_index
)
if authoritative_matrix:
    assert set(baseline_container_index) == set(container_index)

container_contract_red_path = None
container_contract_red_untrusted_result = None
container_contract_red_trusted_result = None
if authoritative_matrix:
    # RED proof against a tautological container contract: appending a
    # structurally empty list passes when the contract is rebuilt after
    # mutation, but fails against the embedded trusted contract at the exact
    # occurrence path.
    container_contract_red_path = (
        "fixtures", "library-15959", "itemOrderParity", "byShape", "All", "301", "observedCounts"
    )
    container_contract_red_report = copy.deepcopy(report)
    container_contract_red_target = container_contract_red_report
    for part in container_contract_red_path[:-1]:
        container_contract_red_target = container_contract_red_target[part]
    container_contract_red_target[container_contract_red_path[-1]].append([])
    container_contract_red_documents = [
        ("report", container_contract_red_report),
        ("benchmarkManifest", copy.deepcopy(manifest)),
    ]
    container_contract_red_untrusted = validator.build_container_validation_index(container_contract_red_documents)
    container_contract_red_untrusted_result = validator.validate_documents(
        container_contract_red_documents,
        schema,
        nullable_schema,
        trusted,
        container_schema=container_contract_red_untrusted,
    )
    assert container_contract_red_untrusted_result["valid"]
    container_contract_red_trusted_result = validator.validate_documents(
        container_contract_red_documents,
        schema,
        nullable_schema,
        trusted,
        container_schema=validator.build_trusted_container_validation_index(("library-15959",)),
    )
    assert not container_contract_red_trusted_result["valid"]
    assert any(
        error.get("code") == "container-cardinality"
        and error.get("label") == "report"
        and tuple(error.get("path", ())) == container_contract_red_path
        for error in container_contract_red_trusted_result["errors"]
    )
baseline_result = validator.validate_documents(
    baseline_documents,
    schema,
    nullable_schema,
    trusted,
)
assert baseline_result["valid"], baseline_result["errors"][:5]
assert baseline_result["baselineNumericScalarLeaves"] == baseline_result["visitedNumericScalarLeaves"]
assert baseline_result["baselineNumericScalarLeaves"] == baseline_result["validatedNumericScalarLeaves"]
assert baseline_result["missingNumericScalarLeaves"] == 0
assert baseline_result["unexpectedNumericScalarLeaves"] == 0
assert baseline_result["duplicateNumericScalarLeaves"] == 0

# Scale-safety GREEN proof: copied fixture data is presented as a post-
# benchmark 50k/100k report.  The trusted semantic validator must accept it
# without loading the pinned 15959 container occurrence contract.  This is a
# synthetic invocation only; no 50k/100k benchmark or live Library access is
# performed here.
synthetic_source_fixture = next(iter(report.get("fixtures", {}).values()))
synthetic_report = copy.deepcopy(report)
synthetic_report["fixtures"] = {
    f"library-{scale}": copy.deepcopy(synthetic_source_fixture)
    for scale in (50000, 100000)
}
synthetic_manifest = copy.deepcopy(manifest)
synthetic_manifest["scales"] = [50000, 100000]
synthetic_documents = [
    ("report", synthetic_report),
    ("benchmarkManifest", synthetic_manifest),
]
synthetic_schema = validator.build_schema(synthetic_documents, trusted)
synthetic_nullable_schema = validator.build_nullable_schema(synthetic_documents)
synthetic_result = validator.validate_documents(
    synthetic_documents,
    synthetic_schema,
    synthetic_nullable_schema,
    trusted,
    exact_family_set=True,
)
assert synthetic_result["valid"], synthetic_result["errors"][:5]
synthetic_container_index = validator.build_container_validation_index(synthetic_documents)
assert synthetic_container_index
assert all(
    "library-15959" not in repr(path)
    for _, path in synthetic_container_index
)
synthetic_scale_safety = {
    "requestedScales": [50000, 100000],
    "authoritativeMatrix": False,
    "trustedContainerContractScope": [],
    "baselineContainerIndexOnlyForCensus": True,
    "valid": synthetic_result["valid"],
    "containerOccurrences": len(synthetic_container_index),
}

# Trusted-cardinality RED proof: remove one numeric family, then deliberately
# rebuild the candidate scalar schema from that malformed report.  The
# document-derived schema therefore cannot notice the omission itself; the
# independent trusted family/cardinality contract must still reject it.
missing_family_scope = sorted(report["fixtures"])[0]
missing_family_report = copy.deepcopy(report)
missing_family_target = missing_family_report["fixtures"][missing_family_scope]["fullTotalTarget"]
missing_family_target.pop("metric")
missing_family_documents = [
    ("report", missing_family_report),
    ("benchmarkManifest", copy.deepcopy(manifest)),
]
missing_family_schema = validator.build_schema(missing_family_documents, trusted)
missing_family_nullable_schema = validator.build_nullable_schema(missing_family_documents)
missing_family_result = validator.validate_documents(
    missing_family_documents,
    missing_family_schema,
    missing_family_nullable_schema,
    trusted,
    exact_family_set=True,
)
assert not missing_family_result["valid"]
assert any(
    error.get("code") in {"missing-structural-family", "structural-family-cardinality"}
    and error.get("scope") in (None, missing_family_scope)
    and tuple(error.get("family", ())) == ("fixtures", "<library>", "fullTotalTarget", "metric")
    for error in missing_family_result["errors"]
)

all_numeric_targets = sorted(
    ((label, path) for label, path, _ in schema),
    key=lambda target: (target[0], repr(target[1])),
)
assert len(all_numeric_targets) == len(set(all_numeric_targets))
numeric_targets = [
    target for position, target in enumerate(all_numeric_targets)
    if position % shard_count == shard_index
]
families = {validator.path_family(path) for _, path in all_numeric_targets}
by_label = dict(baseline_documents)
baseline_fingerprints = {
    label: json.dumps(document, sort_keys=True, separators=(",", ":"))
    for label, document in baseline_documents
}

required_paths = {}
for label, path, _ in schema:
    if path == ("pageSizes", 0):
        required_paths["pageSizes"] = (label, path)
    if path == ("scales", 0):
        required_paths["scales"] = (label, path)
    if path[-1] == "keysetPages":
        required_paths.setdefault("keysetPages", (label, path))
    if "observedCounts" in path and path[-1] == 0:
        required_paths.setdefault("observedCounts", (label, path))
    if "requestedPageSizes" in path and path[-1] == 0:
        required_paths.setdefault("requestedPageSizes", (label, path))
    if "itemCount" in path and path[-1] == "itemCount":
        required_paths.setdefault("itemCount", (label, path))
    if path[-1] == "itemCountAfter":
        required_paths["itemCountAfter"] = (label, path)
    if "writer" in path and path[-1] == "count":
        required_paths.setdefault("writer", (label, path))
assert set(required_paths) >= {"scales", "pageSizes", "keysetPages", "itemCount", "observedCounts", "requestedPageSizes", "itemCountAfter", "writer"}

required_markers = {
    "scales": False,
    "pageSizes": False,
    "keysetPages": False,
    "itemCount": False,
    "observedCounts": False,
    "requestedPageSizes": False,
    "itemCountAfter": False,
    "writer": False,
}
for label, path, _ in schema:
    joined = "/".join(str(part) for part in path)
    for marker in required_markers:
        if marker in path or marker in joined:
            required_markers[marker] = True
assert all(required_markers.values()), required_markers

# RED proof: the old batch gate would pass a deliberately broken validator
# that rejects only one concrete path, while the independent path gate catches
# the second path.  This proof is intentionally separate from production
# validation and never supplies a result to the real matrix below.
red_designated_path = all_numeric_targets[0]
red_uncovered_path = all_numeric_targets[1]


def reject_only_designated_path(documents, label, path):
    if (label, path) != red_designated_path:
        return []
    return validator.validate_single_path(documents, label, path, path_index)


red_batch_report = copy.deepcopy(report)
red_batch_manifest = copy.deepcopy(manifest)
red_batch_documents = {"report": red_batch_report, "benchmarkManifest": red_batch_manifest}
for label, path in all_numeric_targets:
    validator.set_path(red_batch_documents[label], path, False)
red_batch_errors = reject_only_designated_path(red_batch_documents, *red_designated_path)
red_old_batch_would_pass = bool(red_batch_errors)
assert red_old_batch_would_pass

red_probe_original = by_label[red_uncovered_path[0]]
red_probe_label, red_probe_path = red_uncovered_path
red_probe_parent = red_probe_original
for part in red_probe_path[:-1]:
    red_probe_parent = red_probe_parent[part]
red_probe_original_value = red_probe_parent[red_probe_path[-1]]
try:
    red_probe_parent[red_probe_path[-1]] = False
    red_new_independent_would_fail = not reject_only_designated_path(by_label, red_probe_label, red_probe_path)
finally:
    red_probe_parent[red_probe_path[-1]] = red_probe_original_value
assert red_new_independent_would_fail


def exact_path_error(errors, label, path, codes):
    assert errors, errors
    for error in errors:
        assert error.get("label") == label, error
        assert tuple(error.get("path", ())) == path, error
    assert any(error.get("code") in codes for error in errors), errors[:3]


def has_container_witness(errors, label, path):
    """Require a target-local production error, including family/scope errors."""
    target_family = validator.path_family(path)
    for error in errors:
        if error.get("label") != label:
            continue
        error_path = error.get("path")
        if error_path is not None and tuple(error_path[: len(path)]) == path:
            return True
        error_family = error.get("family")
        if error_family is not None and tuple(error_family[: len(target_family)]) == target_family:
            if len(path) >= 2 and path[0] == "fixtures" and error.get("scope") not in (None, path[1]):
                continue
            return True
    return False


numeric_leaf_mutation_checks = 0
mutation_paths_by_kind = {}
mutation_path_lists_by_kind = {}
for mutation_name, mutation in (("false", False), ("true", True), ("string", "numeric-mutation"), ("NaN", float("nan"))):
    checks = 0
    checked_paths = []
    for label, path in numeric_targets:
        target = by_label[label]
        parent = target
        for part in path[:-1]:
            parent = parent[part]
        original = parent[path[-1]]
        try:
            parent[path[-1]] = mutation
            errors = validator.validate_single_path(by_label, label, path, path_index)
            exact_path_error(errors, label, path, {"strict-numeric-type"})
            checks += 1
            checked_paths.append({"label": label, "path": list(path)})
        finally:
            parent[path[-1]] = original
    assert checks == len(numeric_targets)
    numeric_leaf_mutation_checks += checks
    mutation_paths_by_kind[mutation_name] = checks
    mutation_path_lists_by_kind[mutation_name] = checked_paths


all_container_targets = sorted(
    (
        (label, path)
        for label, document in baseline_documents
        for path, _ in validator.container_occurrences(document)
    ),
    key=lambda target: (target[0], repr(target[1])),
)
assert len(all_container_targets) == len(set(all_container_targets))
if authoritative_matrix:
    assert len(all_container_targets) == 106
container_targets = [
    target for position, target in enumerate(all_container_targets)
    if position % shard_count == shard_index
]
container_mutation_checks = 0
container_mutation_checks_by_kind = {"missing": 0, "extra": 0, "wrongType": 0, "duplicate": 0}
container_mutation_paths_by_kind = {key: [] for key in container_mutation_checks_by_kind}


def container_parent(document, path):
    parent = document
    for part in path[:-1]:
        parent = parent[part]
    return parent, path[-1]


for mutation_name in ("missing", "extra", "wrongType", "duplicate"):
    for label, path in container_targets:
        contract = container_index[(label, path)]
        if mutation_name == "duplicate" and contract["kind"] == "dict":
            continue
        parent, key = container_parent(by_label[label], path)
        original = parent[key]
        try:
            if mutation_name == "missing":
                del parent[key]
            elif mutation_name == "wrongType":
                parent[key] = False
            else:
                mutated = copy.deepcopy(original)
                if isinstance(mutated, list):
                    if mutation_name == "duplicate":
                        mutated.append(copy.deepcopy(mutated[-1]) if mutated else None)
                    else:
                        mutated.append({"__phase2a4_extra__": True})
                else:
                    if mutation_name == "duplicate":
                        mutated["__phase2a4_duplicate__"] = copy.deepcopy(next(iter(mutated.values())))
                    else:
                        mutated["__phase2a4_extra__"] = True
                parent[key] = mutated
            full_result = validator.validate_documents(
                baseline_documents,
                schema,
                nullable_schema,
                trusted,
            )
            assert not full_result["valid"], f"{mutation_name} container mutation unexpectedly passed"
            assert has_container_witness(full_result["errors"], label, path), {
                "mutation": mutation_name,
                "label": label,
                "path": path,
                "errors": full_result["errors"][:5],
            }
            container_mutation_checks += 1
            container_mutation_checks_by_kind[mutation_name] += 1
            container_mutation_paths_by_kind[mutation_name].append({"label": label, "path": list(path)})
        finally:
            parent[key] = original


expected_container_checks_by_kind = {
    "missing": len(container_targets),
    "extra": len(container_targets),
    "wrongType": len(container_targets),
    "duplicate": sum(
        1 for label, path in container_targets
        if container_index[(label, path)]["kind"] == "list"
    ),
}
assert container_mutation_checks_by_kind == expected_container_checks_by_kind
assert container_mutation_checks == sum(expected_container_checks_by_kind.values())


for label, document in baseline_documents:
    assert json.dumps(document, sort_keys=True, separators=(",", ":")) == baseline_fingerprints[label]

assert validator.nullable_number(None) and validator.nullable_number(0)
assert not validator.nullable_number(False) and not validator.nullable_number(True)
assert baseline_result["nullableNumericPaths"] > 0

all_nullable_schema = sorted(nullable_schema, key=lambda entry: (entry[0], repr(entry[1])))
assert len(all_nullable_schema) == len(set((label, path) for label, path, _ in all_nullable_schema))
nullable_targets = [
    entry for position, entry in enumerate(all_nullable_schema)
    if position % shard_count == shard_index
]
nullable_acceptance_checks_by_kind = {"None": 0, "zero": 0}
for acceptance_name, acceptance_value in (("None", None), ("zero", 0)):
    for label, path, _ in nullable_targets:
        parent = by_label[label]
        for part in path[:-1]:
            parent = parent[part]
        original = parent[path[-1]]
        try:
            parent[path[-1]] = acceptance_value
            errors = validator.validate_single_path(by_label, label, path, path_index)
            assert not errors, errors[:3]
            nullable_acceptance_checks_by_kind[acceptance_name] += 1
        finally:
            parent[path[-1]] = original

nullable_invalid_checks = 0
nullable_invalid_paths_by_kind = {}
nullable_invalid_path_lists_by_kind = {}
for mutation_name, mutation in (("false", False), ("true", True), ("string", "nullable-mutation"), ("NaN", float("nan"))):
    checks = 0
    checked_paths = []
    for label, path, _ in nullable_targets:
        parent = by_label[label]
        for part in path[:-1]:
            parent = parent[part]
        original = parent[path[-1]]
        try:
            parent[path[-1]] = mutation
            errors = validator.validate_single_path(by_label, label, path, path_index)
            exact_path_error(errors, label, path, {"nullable-numeric-type"})
            checks += 1
            checked_paths.append({"label": label, "path": list(path)})
        finally:
            parent[path[-1]] = original
    assert checks == len(nullable_targets)
    nullable_invalid_checks += checks
    nullable_invalid_paths_by_kind[mutation_name] = checks
    nullable_invalid_path_lists_by_kind[mutation_name] = checked_paths

for label, document in baseline_documents:
    assert json.dumps(document, sort_keys=True, separators=(",", ":")) == baseline_fingerprints[label]

# C2 self-test: one combined report with three concrete fixture scopes must
# pass the exact current union/cardinality contract.  The same unmutated
# baseline schema is then reused for missing/duplicate within-fixture RED
# cases, proving cardinality is scoped rather than relaxed globally.
combined_report = copy.deepcopy(report)
combined_manifest = copy.deepcopy(manifest)
if authoritative_matrix:
    source_fixture = copy.deepcopy(report["fixtures"]["library-15959"])
    for scale in (50000, 100000):
        combined_report["fixtures"][f"library-{scale}"] = copy.deepcopy(source_fixture)
    combined_manifest["scales"] = [15959, 50000, 100000]
    combined_fixture_scopes = ["library-15959", "library-50000", "library-100000"]
else:
    # Dynamic scale self-test uses copied fixture data with only post-
    # benchmark scopes, so no 15959 path or exact container length is needed.
    source_fixture = copy.deepcopy(next(iter(report["fixtures"].values())))
    combined_report["fixtures"] = {
        "library-50000": copy.deepcopy(source_fixture),
        "library-100000": copy.deepcopy(source_fixture),
    }
    combined_manifest["scales"] = [50000, 100000]
    combined_fixture_scopes = ["library-50000", "library-100000"]
combined_mutation_scope = "library-50000"
combined_documents = [("report", combined_report), ("benchmarkManifest", combined_manifest)]
combined_schema = validator.build_schema(combined_documents, trusted)
combined_nullable_schema = validator.build_nullable_schema(combined_documents)
combined_result = validator.validate_documents(
    combined_documents,
    combined_schema,
    combined_nullable_schema,
    trusted,
    exact_family_set=True,
)
assert combined_result["valid"], combined_result["errors"][:10]

missing_report = copy.deepcopy(combined_report)
missing_report["fixtures"][combined_mutation_scope]["fullTotalTarget"].pop("metric")
missing_documents = [("report", missing_report), ("benchmarkManifest", copy.deepcopy(combined_manifest))]
missing_result = validator.validate_documents(
    missing_documents,
    combined_schema,
    combined_nullable_schema,
    trusted,
    exact_family_set=True,
)
assert not missing_result["valid"]
assert any(error["code"] == "structural-family-cardinality" and error.get("scope") == combined_mutation_scope
           for error in missing_result["errors"])

duplicate_report = copy.deepcopy(combined_report)
duplicate_report["fixtures"][combined_mutation_scope]["fullProjectionParity"]["meta"]["requestedPageSizes"].append(999)
duplicate_documents = [("report", duplicate_report), ("benchmarkManifest", copy.deepcopy(combined_manifest))]
duplicate_result = validator.validate_documents(
    duplicate_documents,
    combined_schema,
    combined_nullable_schema,
    trusted,
    exact_family_set=True,
)
assert not duplicate_result["valid"]
assert any(error["code"] == "structural-family-cardinality" and error.get("scope") == combined_mutation_scope
           for error in duplicate_result["errors"])

print(json.dumps({
    "matrixMode": "authoritative-15959" if authoritative_matrix else "scale-safe-dynamic",
    "requestedScales": requested_scales,
    "authoritativeMatrix": authoritative_matrix,
    "trustedContainerContractScope": ["library-15959"] if authoritative_matrix else [],
    "baselineContainerIndexUsedOnlyForCensus": not authoritative_matrix,
    "shard": {
        "index": shard_index,
        "count": shard_count,
        "numericTargets": len(numeric_targets),
        "numericTargetsTotal": len(all_numeric_targets),
        "containerTargets": len(container_targets),
        "containerTargetsTotal": len(all_container_targets),
        "nullableTargets": len(nullable_targets),
        "nullableTargetsTotal": len(all_nullable_schema),
    },
    "schemaCoverage": {
        "reportBaselineNumericScalarLeaves": sum(label == "report" for label, _, _ in schema),
        "benchmarkManifestBaselineNumericScalarLeaves": sum(label == "benchmarkManifest" for label, _, _ in schema),
        "baselineNumericScalarLeaves": baseline_result["baselineNumericScalarLeaves"],
        "visitedNumericScalarLeaves": baseline_result["visitedNumericScalarLeaves"],
        "validatedNumericScalarLeaves": baseline_result["validatedNumericScalarLeaves"],
        "missingNumericScalarLeaves": baseline_result["missingNumericScalarLeaves"],
        "unexpectedNumericScalarLeaves": baseline_result["unexpectedNumericScalarLeaves"],
        "duplicateNumericScalarLeaves": baseline_result["duplicateNumericScalarLeaves"],
        "distinctStructuralFamilies": len(families),
        "numericLeafMutationChecks": numeric_leaf_mutation_checks,
        "numericLeafPathChecks": numeric_leaf_mutation_checks,
        "numericLeafMutationPathsPerKind": mutation_paths_by_kind,
        "numericLeafMutationPathListsByKind": mutation_path_lists_by_kind,
        "numericLeafRestoreChecks": numeric_leaf_mutation_checks,
        "containerMutationTargets": len(container_targets),
        "containerOccurrenceCount": len(all_container_targets),
        "containerMutationPaths": [
            {"label": label, "path": list(path)}
            for label, path in container_targets
        ],
        "containerMutationChecks": container_mutation_checks,
        "containerMutationChecksByKind": container_mutation_checks_by_kind,
        "containerMutationPathsByKind": container_mutation_paths_by_kind,
        "containerRestoreChecks": container_mutation_checks,
        "trustedContainerContract": (
            "phase2a4_trusted_schema.load_trusted_container_contract(scope=library-15959)"
            if authoritative_matrix
            else "none-live; baseline container index is census-only"
        ),
        "containerContractRedProof": (
            {
                "path": list(container_contract_red_path),
                "rebuildAfterMutationWouldPass": container_contract_red_untrusted_result["valid"],
                "embeddedTrustedContractFails": not container_contract_red_trusted_result["valid"],
            }
            if authoritative_matrix else None
        ),
        "containerDuplicateNotApplicable": sum(
            1 for label, path in container_targets
            if container_index[(label, path)]["kind"] == "dict"
        ),
        "containerDuplicateApplicable": expected_container_checks_by_kind["duplicate"],
        "allBaselineNumericPathsRejected": all(
            count == len(numeric_targets) for count in mutation_paths_by_kind.values()
        ),
        "nullableNumericPaths": baseline_result["nullableNumericPaths"],
        "nullableNoneAccepted": len(nullable_targets),
        "nullableZeroAccepted": len(nullable_targets),
        "nullableAcceptanceChecksByKind": nullable_acceptance_checks_by_kind,
        "nullableAcceptanceChecks": sum(nullable_acceptance_checks_by_kind.values()),
        "nullableInvalidChecks": nullable_invalid_checks,
        "nullableInvalidPathsPerKind": nullable_invalid_paths_by_kind,
        "nullableInvalidPathListsByKind": nullable_invalid_path_lists_by_kind,
        "nullableRestoreChecks": sum(nullable_acceptance_checks_by_kind.values()) + nullable_invalid_checks,
        "allNullableInvalidPathsRejected": all(
            count == len(nullable_targets) for count in nullable_invalid_paths_by_kind.values()
        ),
        "requiredRepresentatives": required_markers,
        "combinedFixtureCardinalitySelfTest": {
            "pass": combined_result["valid"],
            "fixtureScopes": combined_fixture_scopes,
            "missingWithinFixtureFailsClosed": not missing_result["valid"],
            "duplicateWithinFixtureFailsClosed": not duplicate_result["valid"],
            "missingErrorCodes": sorted({error["code"] for error in missing_result["errors"]}),
            "duplicateErrorCodes": sorted({error["code"] for error in duplicate_result["errors"]}),
        },
        "syntheticScaleSafety": synthetic_scale_safety,
        "trustedMissingFamilyFailsClosed": {
            "scope": missing_family_scope,
            "pass": not missing_family_result["valid"],
            "errorCodes": sorted({error["code"] for error in missing_family_result["errors"]}),
            "family": ["fixtures", "<library>", "fullTotalTarget", "metric"],
        },
        "validator": "phase2a4_numeric_validator.validate_documents",
        "singlePathPrimitive": "phase2a4_numeric_validator.validate_single_path",
        "redProof": {
            "defectiveValidatorRejectsOnly": {"label": red_designated_path[0], "path": list(red_designated_path[1])},
            "oldBatchWouldPass": red_old_batch_would_pass,
            "newIndependentGateWouldFail": red_new_independent_would_fail,
            "uncoveredPath": {"label": red_uncovered_path[0], "path": list(red_uncovered_path[1])},
        },
        "trustedFamilySchemaFingerprint": trusted["fingerprint"],
        "trustedFamilySchemaFamilies": len(trusted["families"]),
        "trustedFixedCardinalityFamilies": len(trusted["fixedCardinality"]),
    }
}, sort_keys=True))
PY
