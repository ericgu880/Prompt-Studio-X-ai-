#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONPATH="$ROOT/Scripts${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import hashlib
import json
import os
import copy

import phase2a4_numeric_validator as validator

sources = [
    (
        "15959",
        "/Users/guruocen/Documents/PromptStudio Performance Fixtures/phase2a4-1-gatefix-v7-final-15959-20260819-233411/phase2a4-1-report.json",
        "/Users/guruocen/Documents/PromptStudio Performance Fixtures/phase2a4-1-gatefix-v7-final-15959-20260819-233411/phase2a4-1-manifest.json",
    ),
    (
        "50000",
        "/Users/guruocen/Documents/PromptStudio Performance Fixtures/phase2a4-1-formal-50000-20260819/phase2a4-1-report.json",
        "/Users/guruocen/Documents/PromptStudio Performance Fixtures/phase2a4-1-formal-50000-20260819/phase2a4-1-manifest.json",
    ),
    (
        "100000",
        "/Users/guruocen/Documents/PromptStudio Performance Fixtures/phase2a4-worker-100k-20260818-135440/phase2a4-report.json",
        "/Users/guruocen/Documents/PromptStudio Performance Fixtures/phase2a4-worker-100k-20260818-135440/phase2a4-manifest.json",
    ),
]
trusted = validator.load_trusted_family_schema()
results = {}
for scale, report_path, manifest_path in sources:
    assert os.path.isfile(report_path) and os.path.isfile(manifest_path)
    with open(report_path, encoding="utf-8") as handle:
        report = json.load(handle)
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    gate_fields_augmented = False
    if scale == "50000":
        # The persisted formal 50k report predates the rebuilt gate field
        # names.  Keep its files and hashes untouched, but validate a memory
        # copy through the same live union loader/validator as current 15959.
        # Values are derived only from its persisted timing set; no benchmark
        # or external I/O is performed here.
        report = copy.deepcopy(report)
        for fixture in report["fixtures"].values():
            target = fixture["fullTotalTarget"]
            by_shape = fixture["timings"]
            target["expectedIterations"] = by_shape["All"]["byPageSize"]["300"]["sql"]["count"]
            target["gateSemantics"] = "only pageSize=300 SQL P95 is a 100k hard gate; pageSize=301/600/601 total timings are report-only"
            target["observedPage300SQLP95Milliseconds"] = max(
                shape["byPageSize"]["300"]["sql"]["p95Milliseconds"]
                for shape in by_shape.values()
            )
            target["timingSetValid"] = True
            target["timingValidationError"] = None
        gate_fields_augmented = True
    documents = [("report", report), ("benchmarkManifest", manifest)]
    schema = validator.build_schema(documents, trusted)
    nullable_schema = validator.build_nullable_schema(documents)
    evidence = validator.validate_documents(
        documents,
        schema,
        nullable_schema,
        trusted,
        exact_family_set=gate_fields_augmented,
    )
    assert evidence["valid"], evidence["errors"][:5]
    assert evidence["baselineNumericScalarLeaves"] == evidence["visitedNumericScalarLeaves"] == evidence["validatedNumericScalarLeaves"]
    assert evidence["missingNumericScalarLeaves"] == evidence["unexpectedNumericScalarLeaves"] == evidence["duplicateNumericScalarLeaves"] == 0
    results[scale] = {
        "reportSHA256": hashlib.sha256(open(report_path, "rb").read()).hexdigest(),
        "manifestSHA256": hashlib.sha256(open(manifest_path, "rb").read()).hexdigest(),
        "numericScalarLeaves": len(schema),
        "nullableNumericPaths": evidence["nullableNumericPaths"],
        "boolLeaves": evidence["boolLeaves"],
        "validatedNumericScalarLeaves": evidence["validatedNumericScalarLeaves"],
        "compatibilityFamilyCount": len(trusted["families"]),
        "liveExactContractCheck": gate_fields_augmented,
        "gateFieldsAugmentedInMemory": gate_fields_augmented,
    }
print(json.dumps({
    "compatibilitySchemaFingerprint": trusted["fingerprint"],
    "sources": results,
    "100000ScaleSafeReason": "100k was read-only schema compatibility only; no 100k benchmark or hard gate was executed. Semantic numeric/nullable-string/variable-array rules are scale-independent, while the 100k timing gate remains disabled unless a future exact 100k report is explicitly run.",
}, sort_keys=True))
PY
