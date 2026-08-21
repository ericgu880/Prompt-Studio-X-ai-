"""Shared strict JSON numeric/schema validator for the Phase 2A4 gate."""

import hashlib
import json
import math
import re
from collections import Counter


NULLABLE_NUMERIC_NAMES = {
    "p50Milliseconds",
    "p95Milliseconds",
    "maxMilliseconds",
    "sqlMilliseconds",
    "decodeMilliseconds",
    "relativeP50ToPhase2A1",
    "observedExitElapsedMilliseconds",
}



def strict_bool(value):
    return type(value) is bool


def strict_int(value):
    return type(value) is int


def strict_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def nullable_number(value):
    return value is None or strict_number(value)


def numeric_leaves(value, path=()):
    if type(value) in (int, float):
        yield path, value
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from numeric_leaves(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from numeric_leaves(child, path + (index,))


def scalar_leaves(value, path=()):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from scalar_leaves(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from scalar_leaves(child, path + (index,))
    else:
        yield path, value


def path_family(path):
    family = []
    for part in path:
        if isinstance(part, int):
            family.append("[]")
        elif part in {"All", "Folder", "Tag", "Type", "Model", "Favorite", "Recent", "Trash", "Combined"}:
            family.append("<shape>")
        elif re.fullmatch(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}", part):
            family.append("<id>")
        elif re.fullmatch(r"(?:item|synthetic|writer|phase2a4)-[A-Za-z0-9_.-]+", part):
            family.append("<id>")
        elif re.fullmatch(r"(?:300|301|600|601)", part):
            family.append("<pageSize>")
        elif re.fullmatch(r"library-\d+", part):
            family.append("<library>")
        else:
            family.append(part)
    return tuple(family)


def _trusted_kind(value, path):
    if value is None:
        return "nullable-number" if path and path[-1] in NULLABLE_NUMERIC_NAMES else "null"
    if type(value) is bool:
        return "bool"
    if type(value) is int:
        return "int"
    if type(value) is float:
        return "number"
    if type(value) is str:
        return "string"
    raise AssertionError(f"unsupported trusted scalar type at {path}: {type(value)}")


def _merge_kinds(existing, incoming):
    if existing == incoming:
        return existing
    if {existing, incoming} <= {"int", "number"}:
        return "number"
    if "nullable-number" in {existing, incoming} and {existing, incoming} <= {"nullable-number", "number", "int", "null"}:
        return "nullable-number"
    if "nullable-string" in {existing, incoming} and {existing, incoming} <= {"nullable-string", "string", "null"}:
        return "nullable-string"
    if "nullable-bool" in {existing, incoming} and {existing, incoming} <= {"nullable-bool", "bool", "null"}:
        return "nullable-bool"
    if "null" in {existing, incoming} and {existing, incoming} <= {"null", "string"}:
        return "nullable-string"
    if "null" in {existing, incoming} and {existing, incoming} <= {"null", "bool"}:
        return "nullable-bool"
    raise AssertionError(f"trusted family has conflicting scalar kinds: {existing}, {incoming}")


def load_trusted_family_schema():
    """Load the pinned, independent schema/family cardinality contract."""
    import phase2a4_trusted_schema

    payload = phase2a4_trusted_schema.load()
    fingerprint_payload = dict(payload)
    expected_fingerprint = fingerprint_payload.pop("schemaFingerprint")
    actual_fingerprint = hashlib.sha256(json.dumps(fingerprint_payload, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    if actual_fingerprint != expected_fingerprint:
        raise AssertionError(f"trusted normalized schema fingerprint changed: {actual_fingerprint}")
    def normalize_trusted_path(path):
        return tuple(
            "<library>" if re.fullmatch(r"library-\d+", part) else
            "<id>" if re.fullmatch(r"(?:item|synthetic|writer|phase2a4)-[A-Za-z0-9_.-]+", part) else part
            for part in path
        )

    families = {}
    cardinality = Counter()
    for entry in payload["families"]:
        family = normalize_trusted_path(entry["path"])
        families[family] = entry["kind"]
        cardinality[family] += entry["cardinality"]
    for field in ("firstPage300SQLP95", "observedAllPageSizesTotalP95Max", "observedAllPageSizesTotalMax"):
        families.pop(("fixtures", "<library>", "fullTotalTarget", field), None)
        cardinality.pop(("fixtures", "<library>", "fullTotalTarget", field), None)
    fixed_cardinality = {
        family: cardinality[family]
        for family in families
        if (
            ("[]" not in family and "<id>" not in family)
            or family[:2] in {("pageSizes", "[]"), ("scales", "[]")}
            or ("requestedPageSizes" in family)
        )
    }
    contract_families = dict(families)
    contract_cardinality = dict(cardinality)
    contract_fixed_cardinality = dict(fixed_cardinality)
    # Live validation uses the semantic union (15959 + formal 50000, with the
    # persisted 100000 diagnostic family set as a scale-safe extension), while
    # the rebuilt 15959 report retains its exact fixed-contract family set.
    semantic_union = load_compatibility_family_schema()
    new_gate_family = ("fixtures", "<library>", "fullTotalTarget", "observedPage300SQLP95Milliseconds")
    # The rebuilt report contract requires this scalar.  It is deliberately
    # added to the independent contract after loading the pinned v7 payload;
    # the old v7 fixture remains a compatibility-only input, while current
    # 15959 reports and an augmented old 50k copy share the same live check.
    contract_families[new_gate_family] = "number"
    contract_cardinality[new_gate_family] = 1
    contract_fixed_cardinality[new_gate_family] = 1
    return {
        "families": semantic_union["families"],
        "contractFamilies": contract_families,
        "cardinality": contract_cardinality,
        "fixedCardinality": contract_fixed_cardinality,
        "fingerprint": semantic_union["fingerprint"],
        "contractFingerprint": expected_fingerprint,
        "sourceReportSHA256": payload["sourceReportSHA256"],
        "sourceManifestSHA256": payload["sourceManifestSHA256"],
        "semanticSources": semantic_union["sources"],
    }


def load_compatibility_family_schema():
    """Load the pinned semantic union used by live and read-only checks."""
    import phase2a4_compat_schema

    payload = phase2a4_compat_schema.load()
    fingerprint_payload = dict(payload)
    expected_fingerprint = fingerprint_payload.pop("schemaFingerprint")
    actual_fingerprint = hashlib.sha256(json.dumps(fingerprint_payload, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    if actual_fingerprint != expected_fingerprint:
        raise AssertionError(f"compatibility schema fingerprint changed: {actual_fingerprint}")
    def normalize_compatibility_path(path):
        return tuple(
            "<library>" if re.fullmatch(r"library-\d+", part) else
            "<id>" if re.fullmatch(r"(?:item|synthetic|writer|phase2a4)-[A-Za-z0-9_.-]+", part) else part
            for part in path
        )

    families = {}
    for entry in payload["families"]:
        family = normalize_compatibility_path(entry["path"])
        if family in families:
            families[family] = _merge_kinds(families[family], entry["kind"])
        else:
            families[family] = entry["kind"]
    families[("fixtures", "<library>", "fullTotalTarget", "observedPage300SQLP95Milliseconds")] = "number"
    return {
        "families": families,
        "cardinality": {},
        "fixedCardinality": {},
        "fingerprint": expected_fingerprint,
        "sources": payload["sources"],
    }


def build_schema(documents, trusted_family_schema=None):
    """Return (label, path, kind) for every baseline numeric scalar leaf."""
    entries = []
    seen = set()
    for label, document in documents:
        for path, value in numeric_leaves(document):
            key = (label, path)
            if key in seen:
                raise AssertionError(f"duplicate numeric path: {label}:{path}")
            seen.add(key)
            if trusted_family_schema is None:
                kind = "int" if type(value) is int else "number"
            else:
                kind = trusted_family_schema["families"].get(path_family(path))
                if kind == "nullable-number":
                    kind = "number"
                if kind not in {"int", "number"}:
                    raise AssertionError(f"numeric leaf has no trusted numeric kind: {label}:{path}:{kind}")
            entries.append((label, path, kind))
    return entries


def build_nullable_schema(documents):
    """Return nullable numeric paths present as None in the baseline."""
    entries = []
    for label, document in documents:
        for path, value in scalar_leaves(document):
            if path and path[-1] in NULLABLE_NUMERIC_NAMES and value is None:
                entries.append((label, path, "nullable-number"))
    return entries


def _lookup(document, path):
    current = document
    for part in path:
        try:
            if isinstance(current, dict) and isinstance(part, str) and part in current:
                current = current[part]
            elif isinstance(current, list) and isinstance(part, int) and 0 <= part < len(current):
                current = current[part]
            else:
                return False, None
        except (IndexError, KeyError, TypeError):
            return False, None
    return True, current


def set_path(document, path, value):
    """Set an existing dict/list path in a test document in place."""
    if not path:
        raise ValueError("cannot replace document root")
    current = document
    for part in path[:-1]:
        current = current[part]
    current[path[-1]] = value


def compile_validation_index(schema, nullable_schema):
    """Compile the exact scalar paths used by both full and single-path checks."""
    numeric = {}
    nullable = {}
    for label, path, kind in schema:
        key = (label, path)
        if key in numeric or key in nullable:
            raise AssertionError(f"duplicate compiled schema path: {label}:{path}")
        numeric[key] = kind
    for label, path, kind in nullable_schema:
        key = (label, path)
        if key in numeric or key in nullable:
            raise AssertionError(f"duplicate compiled schema path: {label}:{path}")
        nullable[key] = kind
    return {"numeric": numeric, "nullable": nullable}


def validate_single_path(by_label, label, path, validation_index):
    """Validate exactly one scalar path using the production strict primitive."""
    key = (label, path)
    numeric = validation_index["numeric"]
    nullable = validation_index["nullable"]
    if key in numeric:
        kind = numeric[key]
    elif key in nullable:
        kind = nullable[key]
    else:
        raise AssertionError(f"path is absent from compiled schema: {label}:{path}")
    found, value = _lookup(by_label[label], path)
    if not found:
        code = "missing-nullable-schema-path" if kind == "nullable-number" else "missing-schema-path"
        return [{"code": code, "label": label, "path": path}]
    if kind == "nullable-number":
        if not nullable_number(value):
            return [{"code": "nullable-numeric-type", "label": label, "path": path}]
    elif not _accepts(kind, value):
        return [{"code": "strict-numeric-type", "label": label, "path": path, "kind": kind}]
    return []


REQUIRED_CONTAINER_NAMES = frozenset(
    {"writer", "requestedPageSizes", "observedCounts", "keysetPages", "pageSizes", "scales"}
)


def container_occurrences(value, names=REQUIRED_CONTAINER_NAMES, path=()):
    """Yield every concrete required-container occurrence, including repeats."""
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = path + (str(key),)
            if str(key) in names and isinstance(child, (dict, list)):
                yield child_path, child
            yield from container_occurrences(child, names, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from container_occurrences(child, names, path + (index,))


def build_container_validation_index(documents, names=REQUIRED_CONTAINER_NAMES):
    """Compile concrete container shape contracts for isolated mutation checks."""
    entries = {}
    for label, document in documents:
        for path, value in container_occurrences(document, names):
            key = (label, path)
            if key in entries:
                raise AssertionError(f"duplicate container path: {label}:{path}")
            if isinstance(value, dict):
                entries[key] = {
                    "kind": "dict",
                    "keys": frozenset(value),
                }
            else:
                entries[key] = {
                    "kind": "list",
                    "length": len(value),
                }
    return entries


def build_trusted_container_validation_index(scopes=("library-15959",)):
    """Load the pinned container contract without inspecting documents."""
    import phase2a4_trusted_schema

    return phase2a4_trusted_schema.load_trusted_container_contract(scopes)


def validate_single_container_path(by_label, label, path, container_index):
    """Validate exactly one concrete container against its production contract."""
    key = (label, path)
    contract = container_index.get(key)
    if contract is None:
        raise AssertionError(f"path is absent from compiled container schema: {label}:{path}")
    found, value = _lookup(by_label[label], path)
    if not found:
        return [{"code": "missing-container", "label": label, "path": path}]
    actual_kind = "dict" if isinstance(value, dict) else "list" if isinstance(value, list) else "scalar"
    if actual_kind != contract["kind"]:
        return [{
            "code": "container-wrong-type",
            "label": label,
            "path": path,
            "expected": contract["kind"],
            "actual": actual_kind,
        }]
    if actual_kind == "dict":
        if frozenset(value) != contract["keys"]:
            return [{
                "code": "container-entries-mismatch",
                "label": label,
                "path": path,
                "expectedKeys": sorted(contract["keys"]),
                "actualKeys": sorted(value),
            }]
    elif len(value) != contract["length"]:
        return [{
            "code": "container-cardinality",
            "label": label,
            "path": path,
            "expected": contract["length"],
            "actual": len(value),
        }]
    return []


def _family_scope(path):
    """Return the cardinality scope for a normalized structural family.

    Fixture-local families must be counted once per concrete library, while
    top-level report/manifest families are shared global structures.  This is
    intentionally derived from the path location, never from the values being
    validated.
    """
    if (
        len(path) >= 2
        and path[0] == "fixtures"
        and isinstance(path[1], str)
        and re.fullmatch(r"library-[0-9]+", path[1])
    ):
        return ("fixture", path[1])
    return ("global",)


def _accepts(kind, value):
    return strict_int(value) if kind == "int" else strict_number(value)


def _accepts_trusted_kind(kind, value):
    if kind == "bool":
        return strict_bool(value)
    if kind == "int":
        return strict_int(value)
    if kind == "number":
        return strict_number(value)
    if kind == "string":
        return type(value) is str
    if kind == "nullable-number":
        return nullable_number(value)
    if kind == "null":
        return value is None
    if kind == "nullable-string":
        return value is None or type(value) is str
    if kind == "nullable-bool":
        return value is None or strict_bool(value)
    return False


def validate_documents(
    documents,
    schema=None,
    nullable_schema=None,
    trusted_family_schema=None,
    exact_family_set=True,
    container_schema=None,
):
    """Validate documents against a fixed baseline schema and return evidence.

    The schema is deliberately supplied by the unmutated baseline. A bool or
    string mutation therefore cannot disappear from numeric traversal and be
    reclassified as an acceptable scalar.
    """
    if schema is None:
        schema = build_schema(documents, trusted_family_schema)
    if nullable_schema is None:
        nullable_schema = build_nullable_schema(documents)
    expected = {(label, path): kind for label, path, kind in schema}
    expected_nullable = {(label, path): kind for label, path, kind in nullable_schema}
    errors = []
    visited = 0
    validated = 0
    by_label = dict(documents)
    validation_index = compile_validation_index(schema, nullable_schema)

    if trusted_family_schema is not None:
        # Type acceptance is always driven by the pinned semantic union.  The
        # 15959 contract families are required in exact mode, but they are not
        # the complete set of families that a later scale may legitimately
        # emit (for example optional summaries and nullable WAL metadata).
        # Keeping lookup and unexpected-family checks on the union prevents a
        # live 50k/100k report from being self-baselined while still allowing
        # union families to be absent/present across scales.
        expected_families = trusted_family_schema["families"]
        expected_cardinality = trusted_family_schema["fixedCardinality"]
        actual_families = Counter()
        scoped_families = Counter()
        actual_fixture_scopes = set()
        expected_fixture_scopes = set()
        for label, document in documents:
            scales = document.get("scales") if isinstance(document, dict) else None
            if isinstance(scales, list):
                expected_fixture_scopes.update(
                    f"library-{scale}"
                    for scale in scales
                    if type(scale) is int and scale >= 0
                )
            for path, value in scalar_leaves(document):
                family = path_family(path)
                actual_families[family] += 1
                scope = _family_scope(path)
                scoped_families[(scope, family)] += 1
                if scope[0] == "fixture":
                    actual_fixture_scopes.add(scope[1])
                expected_kind = expected_families.get(family)
                if expected_kind is None:
                    errors.append({"code": "unexpected-structural-family", "label": label, "path": path, "family": family})
                    continue
                valid = _accepts_trusted_kind(expected_kind, value)
                if not valid:
                    errors.append({"code": "trusted-family-type", "label": label, "path": path, "family": family, "kind": expected_kind})
        required_families = trusted_family_schema.get("contractFamilies", {})
        if exact_family_set and not set(required_families).issubset(actual_families):
            for family in sorted(set(required_families) - set(actual_families), key=repr):
                errors.append({"code": "missing-structural-family", "family": family})
        if exact_family_set:
            for library in sorted(expected_fixture_scopes - actual_fixture_scopes):
                errors.append({"code": "missing-fixture-scope", "scope": library})
            fixture_scopes = sorted(
                actual_fixture_scopes | expected_fixture_scopes
            )
            for family in sorted(expected_cardinality, key=repr):
                if family[:2] == ("fixtures", "<library>"):
                    for library in fixture_scopes:
                        actual = scoped_families[
                            (("fixture", library), family)
                        ]
                        expected_count = expected_cardinality[family]
                        if actual != expected_count:
                            errors.append(
                                {
                                    "code": "structural-family-cardinality",
                                    "family": family,
                                    "scope": library,
                                    "expected": expected_count,
                                    "actual": actual,
                                }
                            )
                    continue
                expected_count = expected_cardinality[family]
                if family == ("scales", "[]"):
                    # The default combined report carries one scale entry per
                    # requested library.  A single-scale report retains its
                    # original exact contract because the derived count is 1.
                    expected_count = sum(
                        len(document["scales"])
                        for _, document in documents
                        if isinstance(document, dict)
                        and isinstance(document.get("scales"), list)
                    )
                actual = scoped_families[(("global",), family)]
                if actual != expected_count:
                    errors.append(
                        {
                            "code": "structural-family-cardinality",
                            "family": family,
                            "scope": "global",
                            "expected": expected_count,
                            "actual": actual,
                        }
                    )
    for label, path, kind in schema:
        visited += 1
        path_errors = validate_single_path(by_label, label, path, validation_index)
        if path_errors:
            errors.extend(path_errors)
        else:
            validated += 1

    for label, path, _ in nullable_schema:
        path_errors = validate_single_path(by_label, label, path, validation_index)
        if path_errors:
            errors.extend(path_errors)

    if container_schema is not None:
        for label, path in container_schema:
            errors.extend(validate_single_container_path(by_label, label, path, container_schema))

    actual = set()
    for label, document in documents:
        actual.update((label, path) for path, _ in numeric_leaves(document))
    baseline_paths = set(expected)
    allowed_paths = baseline_paths | set(expected_nullable)
    for label, path in sorted(baseline_paths - actual, key=repr):
        errors.append({"code": "missing-numeric-leaf", "label": label, "path": path})
    for label, path in sorted(actual - allowed_paths, key=repr):
        errors.append({"code": "unexpected-numeric-leaf", "label": label, "path": path})

    bool_count = 0
    nullable_count = 0
    for label, document in documents:
        for path, value in scalar_leaves(document):
            if type(value) is bool:
                bool_count += 1
                if not strict_bool(value):
                    errors.append({"code": "strict-bool-type", "label": label, "path": path})
            if path and path[-1] in NULLABLE_NUMERIC_NAMES and value is None:
                nullable_count += 1
                if not nullable_number(value):
                    errors.append({"code": "nullable-numeric-type", "label": label, "path": path})

    return {
        "valid": not errors,
        "errors": errors,
        "errorPaths": {(error.get("label"), error.get("path")) for error in errors if "path" in error},
        "baselineNumericScalarLeaves": len(schema),
        "visitedNumericScalarLeaves": visited,
        "validatedNumericScalarLeaves": validated,
        "missingNumericScalarLeaves": sum(error["code"] == "missing-numeric-leaf" for error in errors),
        "unexpectedNumericScalarLeaves": sum(error["code"] == "unexpected-numeric-leaf" for error in errors),
        "duplicateNumericScalarLeaves": 0,
        "boolLeaves": bool_count,
        "nullableNumericPaths": nullable_count,
    }
