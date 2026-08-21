#!/usr/bin/env python3
"""Create and validate isolated Phase 2A query fixtures.

This script never opens the real PromptStudio Library. A caller must provide
an explicit database path for `clone`, and the destination must be outside the
source library. SQLite's online backup API is used so WAL-backed sources are
copied consistently.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import sqlite3
import statistics
import sys
import time
from typing import Any, Iterable


EPOCH = "1970-01-01T00:00:00Z"
DEFAULT_ORDERING = ["sortOrder ASC", "createdAt DESC", "id ASC"]
RECENT_ORDERING = ["lastUsedAt DESC", "createdAt DESC", "id ASC"]


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
    sortOrder INTEGER NOT NULL,
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


ITEM_INSERT = """
INSERT INTO prompt_items (
    id,title,type,assetKind,modelId,modelName,folderId,folderName,category,
    assetPath,thumbnailPath,aspectRatio,width,height,format,fileSize,favorite,
    pinnedAt,deletedAt,createdAt,updatedAt,lastUsedAt,sortOrder,tagsJSON,
    referencesJSON,description,captureId,captureSourceJSON
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
"""


def iso_time(seconds: int) -> str:
    day, remainder = divmod(seconds, 86_400)
    hour, remainder = divmod(remainder, 3_600)
    minute, second = divmod(remainder, 60)
    return f"2026-01-{1 + day:02d}T{hour:02d}:{minute:02d}:{second:02d}Z"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def create_database(path: Path, count: int, seed: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    rng = random.Random(seed + count)
    db = sqlite3.connect(path)
    try:
        db.executescript(SCHEMA)
        folders = [f"folder-{index:03d}" for index in range(24)]
        models = [f"model-{index:03d}" for index in range(10)]
        types = ["image", "video", "text", "audio"]
        kinds = {"image": "image", "video": "video", "text": "markdown", "audio": "audio"}

        db.executemany(
            "INSERT INTO library_folders VALUES (?,?,?,?,?,?,?);",
            [
                (folder, f"Folder {index:03d}", None, None, 0, index, iso_time(index))
                for index, folder in enumerate(folders)
            ],
        )
        db.executemany(
            "INSERT INTO model_profiles VALUES (?,?,?,?,?);",
            [(model, f"Model {index:03d}", types[index % len(types)], "{}", "") for index, model in enumerate(models)],
        )
        db.commit()

        tag_counts = {f"tag-{index:02d}": 0 for index in range(20)}
        items: list[tuple[Any, ...]] = []
        versions: list[tuple[Any, ...]] = []
        for index in range(count):
            item_id = f"item-{index:08d}"
            item_type = types[index % len(types)]
            folder = folders[index % len(folders)]
            model = models[index % len(models)]
            created = iso_time(index // 5)  # deliberate ties
            updated = iso_time(index // 4)
            last_used = EPOCH if index % 6 == 0 else iso_time(index // 7)  # deliberate ties
            deleted = iso_time(index // 9) if index % 17 == 0 else None
            favorite = 1 if index % 5 == 0 else 0
            sort_order = index // 3  # deliberate ties
            tags = [f"tag-{index % 20:02d}", f"tag-{(index + 7) % 20:02d}"]
            for tag in tags:
                if deleted is None:
                    tag_counts[tag] += 1
            references = []
            if index % 7 == 0:
                references.append(
                    {"id": f"ref-{index:08d}", "type": "image", "path": f"references/{item_id}.jpg", "label": "fixture"}
                )
            width = 512 + (index % 7) * 128
            height = 512 + (index % 5) * 192
            file_size = 40_000 + rng.randrange(2_000_000)
            items.append(
                (
                    item_id,
                    f"Fixture {index:08d}",
                    item_type,
                    kinds[item_type],
                    model,
                    f"Model {index % len(models):03d}",
                    folder,
                    f"Folder {index % len(folders):03d}",
                    "fixture",
                    f"assets/{item_id}.dat",
                    f"thumbnails/{item_id}.jpg",
                    f"{width}:{height}",
                    width,
                    height,
                    "PNG" if item_type == "image" else item_type.upper(),
                    file_size,
                    favorite,
                    None,
                    deleted,
                    created,
                    updated,
                    last_used,
                    sort_order,
                    json.dumps(tags, separators=(",", ":")),
                    json.dumps(references, separators=(",", ":")),
                    "fixture description",
                    None,
                    None,
                )
            )
            versions.append(
                (
                    f"version-{index:08d}-0",
                    item_id,
                    "1.0",
                    "" if index % 11 == 0 else f"Prompt {index}",
                    "",
                    "{}",
                    "",
                    created,
                )
            )
            if index % 5 == 0:
                versions.append(
                    (
                        f"version-{index:08d}-1",
                        item_id,
                        "1.1",
                        f"Updated prompt {index}",
                        "",
                        "{}",
                        "",
                        updated,
                    )
                )

        db.execute("BEGIN")
        db.executemany(ITEM_INSERT, items)
        db.executemany("INSERT INTO prompt_versions VALUES (?,?,?,?,?,?,?,?);", versions)
        db.executemany(
            "INSERT INTO tags VALUES (?,?,?,?);",
            [(f"tag-id-{index:02d}", name, "#888888", tag_counts[name]) for index, name in enumerate(sorted(tag_counts))],
        )
        db.commit()
        integrity = db.execute("PRAGMA integrity_check;").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"fixture integrity_check failed: {integrity}")
    finally:
        db.close()


def row_dicts(db: sqlite3.Connection) -> list[dict[str, Any]]:
    db.row_factory = sqlite3.Row
    return [dict(row) for row in db.execute("SELECT * FROM prompt_items;")]


def default_sort(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    # Stable, persisted tie breaker added by Phase 2A while preserving old keys.
    return sorted(rows, key=lambda row: (row["sortOrder"], _descending_text(row["createdAt"]), row["id"]))


def recent_sort(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        rows,
        key=lambda row: (_descending_text(row["lastUsedAt"]), _descending_text(row["createdAt"]), row["id"]),
    )


def _descending_text(value: str) -> tuple[int, ...]:
    # ISO-8601 fixture values are fixed width ASCII; invert bytes for descending order.
    return tuple(-byte for byte in value.encode("utf-8"))


def query_golden(rows: list[dict[str, Any]]) -> dict[str, Any]:
    active = [row for row in rows if row["deletedAt"] is None]
    folder_id = min((row["folderId"] for row in active if row["folderId"]), default="")
    model_id = min((row["modelId"] for row in active if row["modelId"]), default="")
    item_type = "image" if any(row["type"] == "image" for row in active) else min(
        (row["type"] for row in active), default="image"
    )
    scenarios: dict[str, list[dict[str, Any]]] = {
        "all": default_sort(active),
        "folder": default_sort(row for row in active if row["folderId"] == folder_id),
        "type": default_sort(row for row in active if row["type"] == item_type),
        "model": default_sort(row for row in active if row["modelId"] == model_id),
        "favorite": default_sort(row for row in active if row["favorite"] == 1),
        "combined": default_sort(
            row
            for row in active
            if row["folderId"] == folder_id
            and row["type"] == item_type
            and row["modelId"] == model_id
            and row["favorite"] == 1
        ),
        "recent": recent_sort(row for row in active if row["lastUsedAt"] > EPOCH),
        "trash": default_sort(row for row in rows if row["deletedAt"] is not None),
    }
    return {
        "itemCount": len(rows),
        "parameters": {"folderId": folder_id, "modelId": model_id, "type": item_type},
        "ordering": {"default": DEFAULT_ORDERING, "recent": RECENT_ORDERING},
        "queries": {
            name: {"count": len(matches), "ids": [row["id"] for row in matches]}
            for name, matches in scenarios.items()
        },
    }


def write_golden(db_path: Path, output_path: Path) -> dict[str, Any]:
    uri = f"file:{db_path}?mode=ro"
    db = sqlite3.connect(uri, uri=True)
    try:
        payload = query_golden(row_dicts(db))
    finally:
        db.close()
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return payload


def write_manifest(library_dir: Path, source: str, seed: int | None) -> None:
    db_path = library_dir / "database" / "promptstudio.sqlite"
    uri = f"file:{db_path}?mode=ro"
    db = sqlite3.connect(uri, uri=True)
    try:
        item_count = db.execute("SELECT COUNT(*) FROM prompt_items;").fetchone()[0]
        version_count = db.execute("SELECT COUNT(*) FROM prompt_versions;").fetchone()[0]
        integrity = db.execute("PRAGMA integrity_check;").fetchone()[0]
    finally:
        db.close()
    payload = {
        "source": source,
        "seed": seed,
        "itemCount": item_count,
        "versionCount": version_count,
        "integrityCheck": integrity,
        "databaseBytes": db_path.stat().st_size,
        "databaseSHA256": sha256(db_path),
        "goldenSHA256": sha256(library_dir / "golden-results.json"),
        "boundaryScenarios": {
            "pageSizes": [300, 301, 600, 601],
            "continuousPages": 10,
            "deleteBoundaryOrdinal": 299,
            "insertBoundaryOrdinal": 300,
            "reorderInvalidatesCursor": True,
        },
    }
    manifest_path = library_dir / "manifest.json"
    manifest_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    checksum_lines = [
        f"{payload['databaseSHA256']}  database/promptstudio.sqlite",
        f"{payload['goldenSHA256']}  golden-results.json",
        f"{sha256(manifest_path)}  manifest.json",
    ]
    (library_dir / "SHA256SUMS").write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")


def generate(output_root: Path, sizes: list[int], seed: int) -> None:
    output_root.mkdir(parents=True, exist_ok=True)
    for size in sizes:
        started = time.perf_counter()
        library_dir = output_root / f"library-{size}"
        db_path = library_dir / "database" / "promptstudio.sqlite"
        create_database(db_path, size, seed)
        write_golden(db_path, library_dir / "golden-results.json")
        write_manifest(library_dir, source="deterministic-generator", seed=seed)
        print(f"generated {size} rows in {(time.perf_counter() - started):.3f}s at {library_dir}")


def clone(source_db: Path, output_root: Path, name: str) -> None:
    source_db = source_db.resolve()
    library_dir = (output_root / name).resolve()
    if source_db == library_dir / "database" / "promptstudio.sqlite":
        raise ValueError("source and destination databases must differ")
    library_dir.mkdir(parents=True, exist_ok=True)
    destination = library_dir / "database" / "promptstudio.sqlite"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        destination.unlink()
    source = sqlite3.connect(f"file:{source_db}?mode=ro", uri=True)
    target = sqlite3.connect(destination)
    try:
        source.backup(target)
    finally:
        target.close()
        source.close()
    write_golden(destination, library_dir / "golden-results.json")
    write_manifest(library_dir, source=str(source_db), seed=None)
    print(f"online backup created at {library_dir}")


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    position = max(0, math.ceil(len(ordered) * fraction) - 1)
    return ordered[position]


def benchmark(database: Path, iterations: int, output: Path) -> None:
    db = sqlite3.connect(f"file:{database.resolve()}?mode=ro", uri=True)
    golden = json.loads((database.parent.parent / "golden-results.json").read_text(encoding="utf-8"))
    params = golden["parameters"]
    queries = {
        "all": ("SELECT id FROM prompt_items WHERE deletedAt IS NULL ORDER BY sortOrder ASC,createdAt DESC,id ASC LIMIT 300", ()),
        "folder": ("SELECT id FROM prompt_items WHERE deletedAt IS NULL AND folderId=? ORDER BY sortOrder ASC,createdAt DESC,id ASC LIMIT 300", (params["folderId"],)),
        "type": ("SELECT id FROM prompt_items WHERE deletedAt IS NULL AND type=? ORDER BY sortOrder ASC,createdAt DESC,id ASC LIMIT 300", (params["type"],)),
        "model": ("SELECT id FROM prompt_items WHERE deletedAt IS NULL AND modelId=? ORDER BY sortOrder ASC,createdAt DESC,id ASC LIMIT 300", (params["modelId"],)),
        "favorite": ("SELECT id FROM prompt_items WHERE deletedAt IS NULL AND favorite=1 ORDER BY sortOrder ASC,createdAt DESC,id ASC LIMIT 300", ()),
        "combined": ("SELECT id FROM prompt_items WHERE deletedAt IS NULL AND folderId=? AND type=? AND modelId=? AND favorite=1 ORDER BY sortOrder ASC,createdAt DESC,id ASC LIMIT 300", (params["folderId"], params["type"], params["modelId"])),
        "recent": ("SELECT id FROM prompt_items WHERE deletedAt IS NULL AND lastUsedAt>? ORDER BY lastUsedAt DESC,createdAt DESC,id ASC LIMIT 300", (EPOCH,)),
        "trash": ("SELECT id FROM prompt_items WHERE deletedAt IS NOT NULL ORDER BY sortOrder ASC,createdAt DESC,id ASC LIMIT 300", ()),
    }
    report: dict[str, Any] = {"database": str(database), "iterations": iterations, "queries": {}}
    try:
        for name, (sql, values) in queries.items():
            durations: list[float] = []
            for _ in range(iterations):
                started = time.perf_counter_ns()
                list(db.execute(sql, values))
                durations.append((time.perf_counter_ns() - started) / 1_000_000)
            explain = [" ".join(str(value) for value in row) for row in db.execute("EXPLAIN QUERY PLAN " + sql, values)]
            report["queries"][name] = {
                "p50Milliseconds": statistics.median(durations),
                "p95Milliseconds": percentile(durations, 0.95),
                "explain": explain,
            }
    finally:
        db.close()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)
    generate_parser = commands.add_parser("generate")
    generate_parser.add_argument("--output-root", type=Path, required=True)
    generate_parser.add_argument("--sizes", type=int, nargs="+", required=True)
    generate_parser.add_argument("--seed", type=int, default=20260817)
    clone_parser = commands.add_parser("clone")
    clone_parser.add_argument("--source-db", type=Path, required=True)
    clone_parser.add_argument("--output-root", type=Path, required=True)
    clone_parser.add_argument("--name", required=True)
    benchmark_parser = commands.add_parser("benchmark")
    benchmark_parser.add_argument("--database", type=Path, required=True)
    benchmark_parser.add_argument("--iterations", type=int, default=30)
    benchmark_parser.add_argument("--output", type=Path, required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    if args.command == "generate":
        generate(args.output_root, args.sizes, args.seed)
    elif args.command == "clone":
        clone(args.source_db, args.output_root, args.name)
    elif args.command == "benchmark":
        benchmark(args.database, args.iterations, args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
