#!/usr/bin/env python3
"""Generate isolated PromptStudio Phase 2A.3 detail fixtures.

The script deliberately has no dependency on the real PromptStudio Library.
Generated fixture roots are restricted to ``PromptStudio Performance Fixtures``
and source scale libraries are copied with sqlite3's online backup API.  The
golden file contains only hashes and lengths, never persisted prompt text or
asset paths.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import posixpath
from pathlib import Path
import sqlite3
import sys
from typing import Any, Iterable


PERFORMANCE_ROOT = Path("/Users/guruocen/Documents/PromptStudio Performance Fixtures")
SOURCE_ROOT = PERFORMANCE_ROOT / "phase2a1-20260817"
VERSION_COUNTS = (1, 10, 100, 500)
REFERENCE_COUNTS = (0, 1, 20, 100)
REPLICA_COUNT = 8
SELECTION_COUNT = 32
SCALE_COUNTS = (15_959, 50_000, 100_000)
REAL_LIBRARY_ROOT = Path("/Users/guruocen/Documents/PromptStudio Library")

SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE prompt_items (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    type TEXT NOT NULL,
    assetKind TEXT NOT NULL DEFAULT 'image',
    modelId TEXT NOT NULL,
    modelName TEXT NOT NULL,
    folderId TEXT NOT NULL DEFAULT '',
    folderName TEXT NOT NULL,
    category TEXT NOT NULL,
    assetPath TEXT NOT NULL,
    thumbnailPath TEXT NOT NULL,
    aspectRatio TEXT NOT NULL,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    format TEXT NOT NULL,
    fileSize INTEGER NOT NULL,
    favorite INTEGER NOT NULL,
    pinnedAt TEXT,
    deletedAt TEXT,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastUsedAt TEXT NOT NULL,
    sortOrder INTEGER NOT NULL DEFAULT 0,
    tagsJSON TEXT NOT NULL,
    referencesJSON TEXT NOT NULL,
    description TEXT NOT NULL,
    captureId TEXT,
    captureSourceJSON TEXT
);
CREATE TABLE prompt_versions (
    id TEXT PRIMARY KEY,
    promptItemId TEXT NOT NULL,
    version TEXT NOT NULL,
    prompt TEXT NOT NULL,
    negativePrompt TEXT NOT NULL,
    parametersJSON TEXT NOT NULL,
    note TEXT NOT NULL,
    createdAt TEXT NOT NULL,
    FOREIGN KEY(promptItemId) REFERENCES prompt_items(id) ON DELETE CASCADE
);
CREATE TABLE tags (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    color TEXT NOT NULL,
    count INTEGER NOT NULL
);
CREATE TABLE model_profiles (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    parametersJSON TEXT NOT NULL,
    defaultNegativePrompt TEXT NOT NULL
);
CREATE TABLE library_folders (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parentId TEXT,
    type TEXT,
    count INTEGER NOT NULL,
    sortOrder INTEGER NOT NULL,
    createdAt TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_prompt_items_capture_id
ON prompt_items(captureId) WHERE captureId IS NOT NULL;
"""

ITEM_COLUMNS = (
    "id,title,type,assetKind,modelId,modelName,folderId,folderName,category,"
    "assetPath,thumbnailPath,aspectRatio,width,height,format,fileSize,favorite,"
    "pinnedAt,deletedAt,createdAt,updatedAt,lastUsedAt,sortOrder,tagsJSON,"
    "referencesJSON,description,captureId,captureSourceJSON"
)
ITEM_INSERT = f"INSERT INTO prompt_items ({ITEM_COLUMNS}) VALUES ({','.join('?' for _ in ITEM_COLUMNS.split(','))})"
VERSION_INSERT = "INSERT INTO prompt_versions VALUES (?,?,?,?,?,?,?,?)"


def iso_time(seconds: int) -> str:
    return (
        dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=seconds)
    ).isoformat().replace("+00:00", "Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_output_root(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    performance = PERFORMANCE_ROOT.resolve()
    if "PromptStudio Library" in str(resolved):
        raise ValueError("refusing to access the real PromptStudio Library")
    if resolved.parent != performance or not resolved.name.startswith("phase2a3-"):
        raise ValueError(
            f"phase2a3 fixture roots must be {PERFORMANCE_ROOT}/phase2a3-* (got {resolved})"
        )
    return resolved


def _canonical(value: Any) -> bytes:
    # Key sorting keeps the independent Python golden stable across Swift and
    # Python dictionary implementations; array order remains significant.
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def hash_length(value: Any) -> dict[str, Any]:
    encoded = _canonical(value)
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "length": len(encoded)}


def selection_ids(version_count: int, reference_count: int, replica: int) -> list[str]:
    prefix = f"phase2a3-v{version_count}-r{reference_count}-rep{replica}"
    return [f"{prefix}-item-{index:02d}" for index in range(SELECTION_COUNT)]


def reference_rows(item_id: str, count: int) -> list[dict[str, str]]:
    return [
        {
            "id": f"{item_id}-ref-{index:03d}",
            "type": "image",
            "path": f"fixture://references/{item_id}/{index:03d}",
            "label": f"fixture-reference-{index:03d}",
        }
        for index in range(count)
    ]


def item_rows(
    version_count: int,
    reference_count: int,
    replica: int,
    giant: bool = False,
) -> Iterable[tuple[tuple[Any, ...], list[tuple[Any, ...]]]]:
    for index, item_id in enumerate(selection_ids(version_count, reference_count, replica)):
        created = iso_time(index)
        refs = reference_rows(item_id, reference_count)
        item = (
            item_id,
            f"fixture-title-{index:02d}",
            "image",
            "image",
            "fixture-model",
            "Fixture Model",
            "fixture-folder",
            "Fixture Folder",
            "phase2a3",
            f"fixture://assets/{item_id}",
            f"fixture://thumbnails/{item_id}",
            "1:1",
            512,
            512,
            "PNG",
            0,
            0,
            None,
            None,
            created,
            created,
            created,
            index,
            json.dumps(["fixture-tag"], ensure_ascii=False, separators=(",", ":")),
            json.dumps(refs, ensure_ascii=False, separators=(",", ":")),
            "fixture detail benchmark row",
            None,
            None,
        )
        versions: list[tuple[Any, ...]] = []
        for version_index in range(version_count):
            prompt = f"fixture://prompt/{item_id}/{version_index:04d}"
            if giant and index == 0 and version_index == 0:
                prompt += "-" + ("g" * 1_000_000)
            versions.append(
                (
                    f"{item_id}-version-{version_index:04d}",
                    item_id,
                    f"{version_index + 1}.0",
                    prompt,
                    "fixture://negative/empty",
                    json.dumps({"seed": str(version_index)}, separators=(",", ":")),
                    f"fixture-note-{version_index:04d}",
                    iso_time(version_index),
                )
            )
        yield item, versions


def _database_metadata(db: sqlite3.Connection) -> dict[str, Any]:
    integrity = str(db.execute("PRAGMA integrity_check;").fetchone()[0])
    foreign_keys = db.execute("PRAGMA foreign_key_check;").fetchall()
    counts = {
        table: int(db.execute(f"SELECT COUNT(*) FROM {table};").fetchone()[0])
        for table in ("prompt_items", "prompt_versions", "tags", "model_profiles", "library_folders")
    }
    return {
        "integrityCheck": integrity,
        "foreignKeyViolationCount": len(foreign_keys),
        "tableRowCounts": counts,
    }


def _golden(db_path: Path, ids: list[str], version_count: int, reference_count: int) -> dict[str, Any]:
    field_names = ITEM_COLUMNS.split(",")
    items: dict[str, Any] = {}
    with sqlite3.connect(db_path) as db:
        db.row_factory = sqlite3.Row
        for item_id in ids:
            row = db.execute("SELECT * FROM prompt_items WHERE id = ?;", (item_id,)).fetchone()
            if row is None:
                raise RuntimeError(f"missing fixture selection {item_id}")
            fields = {}
            for name in field_names:
                value: Any = row[name]
                if name in {"tagsJSON", "referencesJSON", "captureSourceJSON"} and value is not None:
                    value = json.loads(value)
                fields[name] = hash_length(value)
            version_rows = [
                dict(version)
                for version in db.execute(
                    "SELECT id,promptItemId,version,prompt,negativePrompt,parametersJSON,note,createdAt "
                    "FROM prompt_versions WHERE promptItemId = ? ORDER BY createdAt ASC, id ASC;",
                    (item_id,),
                )
            ]
            references = json.loads(row["referencesJSON"])
            version_fields = {}
            for name in ("id", "promptItemId", "version", "prompt", "negativePrompt", "parametersJSON", "note", "createdAt"):
                values: list[Any] = [version[name] for version in version_rows]
                if name == "parametersJSON":
                    values = [json.loads(value) for value in values]
                version_fields[name] = hash_length(values)
            items[item_id] = {
                "fields": fields,
                "versions": {
                    "count": len(version_rows),
                    "order": hash_length(
                        [[version[name] for name in ("id", "version", "createdAt")] for version in version_rows]
                    ),
                    "fields": version_fields,
                },
                "references": {
                    "count": len(references),
                    "order": hash_length(references),
                    "fields": {
                        name: hash_length([reference[name] for reference in references])
                        for name in ("id", "type", "path", "label")
                    },
                },
            }
    return {
        "schema": "full-promptstudio-schema",
        "itemCount": len(ids),
        "selectionIDs": ids,
        "cardinality": {"versions": version_count, "references": reference_count},
        "items": items,
    }


def _write_fixture_manifest(
    library_root: Path,
    *,
    fixture_kind: str,
    versions: int | None,
    references: int | None,
    replica: int | None,
    source: str | None = None,
    source_sha_before: str | None = None,
    source_sha_after: str | None = None,
) -> dict[str, Any]:
    database = library_root / "database" / "promptstudio.sqlite"
    with sqlite3.connect(database) as db:
        metadata = _database_metadata(db)
    manifest: dict[str, Any] = {
        "fixtureKind": fixture_kind,
        "database": str(database),
        "databaseSHA256": sha256(database),
        "databaseBytes": database.stat().st_size,
        "integrityCheck": metadata["integrityCheck"],
        "foreignKeyViolationCount": metadata["foreignKeyViolationCount"],
        "tableRowCounts": metadata["tableRowCounts"],
        "selectionCount": SELECTION_COUNT if fixture_kind == "matrix" else 0,
    }
    if versions is not None:
        manifest["versions"] = versions
    if references is not None:
        manifest["references"] = references
    if replica is not None:
        manifest["replica"] = replica
    if source is not None:
        manifest["source"] = source
        manifest["sourceSHA256Before"] = source_sha_before
        manifest["sourceSHA256After"] = source_sha_after
        manifest["sourceUnchanged"] = source_sha_before == source_sha_after
    manifest_path = library_root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return manifest


def _write_checksums(library_root: Path, files: Iterable[Path]) -> None:
    lines = []
    for path in files:
        lines.append(f"{sha256(path)}  {path.relative_to(library_root)}")
    (library_root / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")


def _canonical_db_path(raw_path: Any, base: Path) -> str:
    """Canonicalize a DB path string without resolving/opening filesystem media.

    ``abspath``/``normpath`` are intentionally lexical operations.  They do
    not follow symlinks or touch the path, which keeps validation safe for the
    isolated benchmark while still catching ``../PromptStudio Library``
    escapes in relative source rows.
    """
    value = str(raw_path)
    candidate = value if os.path.isabs(value) else os.path.join(str(base), value)
    return posixpath.normpath(os.path.abspath(candidate))


def _is_forbidden_real_library_path(raw_path: Any, base: Path) -> bool:
    canonical = _canonical_db_path(raw_path, base)
    forbidden = posixpath.normpath(str(REAL_LIBRARY_ROOT))
    return canonical == forbidden or canonical.startswith(forbidden + "/")


def _opaque_scale_path(kind: str, raw_path: Any) -> str:
    digest = hashlib.sha256(str(raw_path).encode("utf-8")).hexdigest()
    return f"fixture://opaque-scale/{kind}/{digest}"


def _validate_scale_media_path_strings(database: Path) -> None:
    """Check every scale asset/reference string without resolving/opening media."""
    library_root = database.parent.parent
    uri = f"file:{database.as_posix()}?mode=ro"
    with sqlite3.connect(uri, uri=True) as db:
        journal_mode = str(db.execute("PRAGMA journal_mode;").fetchone()[0]).lower()
        if journal_mode != "delete":
            raise ValueError(f"scale clone must remain DELETE journal mode: {database} ({journal_mode})")
        rows = db.execute(
            "SELECT assetPath, thumbnailPath, referencesJSON FROM prompt_items;"
        )
        for asset_path, thumbnail_path, references_json in rows:
            paths = (asset_path, thumbnail_path)
            references = json.loads(references_json or "[]")
            paths += tuple(reference.get("path", "") for reference in references)
            for path in paths:
                if path and not str(path).startswith("fixture://opaque-scale/"):
                    raise ValueError(
                        "scale DB path is not an opaque fixture URL: "
                        f"{database}: {path}"
                    )
                if _is_forbidden_real_library_path(path, library_root):
                    raise ValueError(
                        "scale DB path points into the real PromptStudio Library: "
                        f"{database}: {path}"
                    )


def _sanitize_scale_media_path_strings(database: Path, size: int) -> None:
    """Replace source-only media paths in the clone with opaque fixture URLs.

    The 15,959-item isolated source intentionally preserves the source schema,
    but some rows contain canonical paths from the source machine.  The
    benchmark never needs those media files, so rewrite only the destination
    clone's path strings after the online backup.  Source bytes and source
    SHA-256 values remain untouched.
    """
    library_root = database.parent.parent
    with sqlite3.connect(database) as db:
        rows = db.execute(
            "SELECT id, assetPath, thumbnailPath, referencesJSON FROM prompt_items;"
        ).fetchall()
        for item_id, asset_path, thumbnail_path, references_json in rows:
            references = json.loads(references_json or "[]")
            changed = False
            if asset_path:
                asset_path = _opaque_scale_path("asset", asset_path)
                changed = True
            if thumbnail_path:
                thumbnail_path = _opaque_scale_path("thumbnail", thumbnail_path)
                changed = True
            for index, reference in enumerate(references):
                path = reference.get("path", "")
                if path:
                    reference["path"] = _opaque_scale_path("reference", path)
                    changed = True
            if changed:
                db.execute(
                    "UPDATE prompt_items SET assetPath = ?, thumbnailPath = ?, referencesJSON = ? WHERE id = ?;",
                    (asset_path, thumbnail_path, json.dumps(references, ensure_ascii=False, separators=(",", ":")), item_id),
                )
        db.commit()


def create_matrix_fixture(
    library_root: Path,
    version_count: int,
    reference_count: int,
    replica: int,
    *,
    giant: bool = False,
) -> dict[str, Any]:
    database_path = library_root / "database" / "promptstudio.sqlite"
    database_path.parent.mkdir(parents=True, exist_ok=True)
    if database_path.exists():
        database_path.unlink()
    with sqlite3.connect(database_path) as db:
        db.executescript(SCHEMA)
        db.execute("INSERT INTO tags VALUES (?,?,?,?)", ("fixture-tag-id", "fixture-tag", "#888888", SELECTION_COUNT))
        db.execute("INSERT INTO model_profiles VALUES (?,?,?,?,?)", ("fixture-model", "Fixture Model", "image", "{}", ""))
        db.execute("INSERT INTO library_folders VALUES (?,?,?,?,?,?,?)", ("fixture-folder", "Fixture Folder", None, None, SELECTION_COUNT, 0, iso_time(0)))
        for item, versions in item_rows(version_count, reference_count, replica, giant=giant):
            db.execute(ITEM_INSERT, item)
            db.executemany(VERSION_INSERT, versions)
        db.commit()
        metadata = _database_metadata(db)
    if metadata["integrityCheck"] != "ok" or metadata["foreignKeyViolationCount"] != 0:
        raise RuntimeError(f"fixture failed SQLite validation: {library_root}")
    ids = selection_ids(version_count, reference_count, replica)
    golden = _golden(database_path, ids, version_count, reference_count)
    golden_path = library_root / "golden-results.json"
    golden_path.write_text(json.dumps(golden, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    manifest = _write_fixture_manifest(
        library_root,
        fixture_kind="matrix",
        versions=version_count,
        references=reference_count,
        replica=replica,
    )
    _write_checksums(library_root, (database_path, golden_path, library_root / "manifest.json"))
    return manifest


def clone_scale_fixture(root: Path, size: int) -> dict[str, Any]:
    source = SOURCE_ROOT / f"library-{size}" / "database" / "promptstudio.sqlite"
    if not source.is_file():
        raise FileNotFoundError(f"isolated phase2a1 source is missing: {source}")
    destination_root = root / "scales" / f"library-{size}"
    destination = destination_root / "database" / "promptstudio.sqlite"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        destination.unlink()
    before = sha256(source)
    source_uri = f"file:{source.as_posix()}?mode=ro"
    source_db = sqlite3.connect(source_uri, uri=True)
    destination_db = sqlite3.connect(destination)
    try:
        # sqlite3.Connection.backup is SQLite's online backup API.  Do not use
        # FileManager/copyfile: the source may have committed WAL frames.
        source_db.backup(destination_db)
        destination_db.commit()
        # Read-only benchmark handles must not need to create a WAL shared
        # memory sidecar.  Normalize only the destination clone; the source is
        # never checkpointed or otherwise mutated.
        destination_db.execute("PRAGMA journal_mode=DELETE;")
        destination_db.commit()
    finally:
        destination_db.close()
        source_db.close()
    _sanitize_scale_media_path_strings(destination, size)
    after = sha256(source)
    with sqlite3.connect(destination) as db:
        metadata = _database_metadata(db)
        item_count = int(db.execute("SELECT COUNT(*) FROM prompt_items;").fetchone()[0])
    if item_count != size or metadata["integrityCheck"] != "ok" or metadata["foreignKeyViolationCount"] != 0:
        raise RuntimeError(f"scale clone validation failed: {destination}")
    manifest = _write_fixture_manifest(
        destination_root,
        fixture_kind="scale-summary",
        versions=None,
        references=None,
        replica=None,
        source=str(source),
        source_sha_before=before,
        source_sha_after=after,
    )
    manifest["itemCount"] = item_count
    (destination_root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    _write_checksums(destination_root, (destination, destination_root / "manifest.json"))
    return manifest


def generate(root: Path, replicas: int, versions: tuple[int, ...], references: tuple[int, ...], include_scales: bool) -> dict[str, Any]:
    root.mkdir(parents=True, exist_ok=True)
    matrix: list[dict[str, Any]] = []
    for version_count in versions:
        for reference_count in references:
            for replica in range(replicas):
                library_root = root / "matrix" / f"versions-{version_count}" / f"refs-{reference_count}" / f"replica-{replica:02d}"
                manifest = create_matrix_fixture(library_root, version_count, reference_count, replica)
                matrix.append({"path": str(library_root), **manifest})
    giant_root = root / "giant" / "versions-1" / "refs-0" / "replica-00"
    giant_manifest = create_matrix_fixture(giant_root, 1, 0, 0, giant=True)
    scales = []
    if include_scales:
        scales = [clone_scale_fixture(root, size) for size in SCALE_COUNTS]
    manifest = {
        "schema": "phase2a3",
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "fixtureRoot": str(root),
        "matrix": {
            "versions": list(versions),
            "references": list(references),
            "replicas": replicas,
            "selectionIDsPerFixture": SELECTION_COUNT,
            "fixtures": matrix,
        },
        "giant": {"path": str(giant_root), **giant_manifest},
        "scales": scales,
        "sourceRoot": str(SOURCE_ROOT),
        "syntheticMatrixPathsAreFixtureURLs": True,
        "scalePathsAreOpaque": True,
        "mediaPathsResolvedOrOpened": False,
    }
    manifest_path = root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (root / "README.json").write_text(
        json.dumps(
            {
                "purpose": "PromptStudio Phase 2A.3 isolated detail benchmark",
                "syntheticMatrixPathsAreFixtureURLs": True,
                "scalePathsAreOpaque": True,
                "mediaPathsResolvedOrOpened": False,
                "pathInterpretation": "synthetic matrix rows use fixture://; scale asset/reference values remain opaque DB strings and are never resolved or opened",
                "golden": "hashes and lengths only; prompt/reference payloads are not emitted",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return manifest


def validate(root: Path) -> None:
    root = safe_output_root(root)
    manifest_path = root / "manifest.json"
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    if payload.get("schema") != "phase2a3":
        raise ValueError("not a phase2a3 fixture root")
    if payload.get("syntheticMatrixPathsAreFixtureURLs") is not True:
        raise ValueError("matrix path integrity metadata is missing")
    if payload.get("scalePathsAreOpaque") is not True or payload.get("mediaPathsResolvedOrOpened") is not False:
        raise ValueError("scale path interpretation metadata is unsafe")
    for entry in payload.get("matrix", {}).get("fixtures", []):
        path = Path(entry["path"])
        resolved_path = path.expanduser().resolve()
        if not str(resolved_path).startswith(str(root) + "/") or "PromptStudio Library" in str(resolved_path):
            raise ValueError(f"fixture manifest escapes isolated root: {path}")
        database = path / "database" / "promptstudio.sqlite"
        golden = json.loads((path / "golden-results.json").read_text(encoding="utf-8"))
        if len(golden.get("selectionIDs", [])) != SELECTION_COUNT:
            raise ValueError(f"selection count mismatch: {path}")
        with sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True) as db:
            metadata = _database_metadata(db)
            paths = db.execute(
                "SELECT assetPath,thumbnailPath,referencesJSON FROM prompt_items LIMIT ?;",
                (SELECTION_COUNT,),
            ).fetchall()
        if metadata["integrityCheck"] != "ok" or metadata["foreignKeyViolationCount"] != 0:
            raise ValueError(f"SQLite validation failed: {database}")
        for asset_path, thumbnail_path, references_json in paths:
            if not str(asset_path).startswith("fixture://") or not str(thumbnail_path).startswith("fixture://"):
                raise ValueError(f"non-fixture asset path in {database}")
            references = json.loads(references_json)
            if any(not str(reference.get("path", "")).startswith("fixture://") for reference in references):
                raise ValueError(f"non-fixture reference path in {database}")
    for entry in payload.get("scales", []):
        source = Path(entry["source"])
        expected_source = SOURCE_ROOT / Path(source).parent.parent.name / "database" / "promptstudio.sqlite"
        if source.expanduser().resolve() != expected_source.resolve() or "PromptStudio Library" in str(source):
            raise ValueError(f"scale manifest source is not an isolated phase2a1 fixture: {source}")
        before = sha256(source)
        after = sha256(source)
        if before != entry.get("sourceSHA256Before") or after != entry.get("sourceSHA256After"):
            raise ValueError(f"source changed after clone: {source}")
        _validate_scale_media_path_strings(Path(entry["database"]))


def parse_ints(raw: str) -> tuple[int, ...]:
    values = tuple(int(value) for value in raw.split(",") if value.strip())
    if not values or any(value < 0 for value in values):
        raise argparse.ArgumentTypeError("expected one or more non-negative integers")
    return values


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("--output-root", type=Path)
    generate_parser.add_argument("--replicas", type=int, default=REPLICA_COUNT)
    generate_parser.add_argument("--versions", type=parse_ints, default=VERSION_COUNTS)
    generate_parser.add_argument("--references", type=parse_ints, default=REFERENCE_COUNTS)
    generate_parser.add_argument("--no-scales", action="store_true")
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "generate":
            timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
            root = safe_output_root(args.output_root or PERFORMANCE_ROOT / f"phase2a3-{timestamp}")
            if args.replicas < 8:
                raise ValueError("phase2a3 requires at least 8 replicas")
            if any(value <= 0 for value in args.versions) or any(value < 0 for value in args.references):
                raise ValueError("versions must be positive and references must be non-negative")
            payload = generate(root, args.replicas, args.versions, args.references, not args.no_scales)
            print(json.dumps({"fixtureRoot": str(root), "matrixFixtures": len(payload["matrix"]["fixtures"])}, sort_keys=True))
        else:
            validate(args.output_root)
            print(f"validated {args.output_root}")
    except (OSError, sqlite3.Error, ValueError, RuntimeError) as error:
        print(f"phase2a3 fixture error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
