"""Pinned normalized scalar-family schema for the Phase 2A4 gate.

The payload was generated once from the recorded v7 fixture SHAs and includes
the rebuilt gate's explicit replacement field. It is intentionally independent
of the report currently being validated.
"""

import base64
import gzip
import json

_PAYLOAD = """
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
"""


def load():
    return json.loads(gzip.decompress(base64.b64decode(_PAYLOAD)))


_SHAPES = ("All", "Combined", "Favorite", "Folder", "Model", "Recent", "Tag", "Trash", "Type")
_PAGE_SIZES = (300, 301, 600, 601)
_WRITER_KEYS = frozenset(
    {
        "batchSequenceInvariants",
        "busy",
        "concurrentConnections",
        "firstPartyRepositoryOnly",
        "itemCountAfter",
        "locked",
        "pass",
        "stages",
        "tagMutation",
        "writerPostWriteContract",
    }
)


def load_trusted_container_contract(scopes=("library-15959",)):
    """Return the pinned 15959 container shape contract, independent of input."""
    entries = {}

    def add(path, kind, **shape):
        key = ("report", tuple(path))
        if key in entries:
            raise AssertionError(f"duplicate trusted container path: {key}")
        entries[key] = {"kind": kind, **shape}

    for scope in scopes:
        root = ("fixtures", scope)
        add(root + ("costs", "writer"), "dict", keys=_WRITER_KEYS)
        add(root + ("fullProjectionParity", "meta", "requestedPageSizes"), "list", length=4)
        add(root + ("fullSQLHashParity", "meta", "requestedPageSizes"), "list", length=4)
        add(root + ("keysetPages",), "dict", keys=frozenset(_SHAPES))
        add(root + ("migrationResume", "migrationResumeOracle", "fullSQLHashParity", "__meta", "requestedPageSizes"), "list", length=1)

        for shape in _SHAPES:
            for page_size in _PAGE_SIZES:
                count = 54 if shape == "All" and page_size == 300 else 33 if shape == "Type" and page_size == 300 else 3 if shape in {"All", "Type"} else 1
                add(root + ("itemOrderParity", "byShape", shape, str(page_size), "observedCounts"), "list", length=count)
            keyset_count = 10 if shape in {"All", "Type"} else 1
            add(root + ("keysetPages", shape, "observedCounts"), "list", length=keyset_count)
            add(root + ("summaryValidation", "counts", shape, "observedCounts"), "list", length=54 if shape == "All" else 33 if shape == "Type" else 1)
            for stability_phase in ("afterOnlineBackup", "afterProcessRestart", "afterVacuum", "before", "freshHandleReopen"):
                add(root + ("stability", stability_phase, shape, "pageSizes"), "list", length=1 if stability_phase == "afterProcessRestart" else 4)


    add(("pageSizes",), "list", length=4)

    manifest_key = ("benchmarkManifest", ("scales",))
    if manifest_key in entries:
        raise AssertionError(f"duplicate trusted container path: {manifest_key}")
    entries[manifest_key] = {"kind": "list", "length": len(scopes)}
    return entries
