#!/usr/bin/env python3
"""Generate and benchmark the Phase 2A.2 relation-backed tag query.

The default output lives outside the repository and outside the real PromptStudio
Library. The benchmark drops and recreates the relation index on each fixture
so the report contains a before/after EXPLAIN and comparable keyset timings.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import resource
import sqlite3
import statistics
import time
import unicodedata
from typing import Any, Iterable


PERFORMANCE_ROOT = Path("/Users/guruocen/Documents/PromptStudio Performance Fixtures")
INDEX_NAME = "idx_phase2a2_prompt_item_tags_tag_order"
SIZES = (15_959, 50_000, 100_000)
PAGE_SIZE = 300
TAG_NAME = "Foo"

SCHEMA = f"""
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
    description TEXT NOT NULL
);
CREATE TABLE prompt_versions (
    id TEXT PRIMARY KEY,
    promptItemId TEXT NOT NULL REFERENCES prompt_items(id) ON DELETE CASCADE,
    version TEXT NOT NULL,
    prompt TEXT NOT NULL,
    negativePrompt TEXT NOT NULL,
    parametersJSON TEXT NOT NULL,
    note TEXT NOT NULL,
    createdAt TEXT NOT NULL
);
CREATE TABLE prompt_item_tags (
    promptItemId TEXT NOT NULL REFERENCES prompt_items(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    tagName TEXT COLLATE BINARY NOT NULL,
    tagKey TEXT COLLATE BINARY NOT NULL,
    isFirstOccurrence INTEGER NOT NULL,
    isDeleted INTEGER NOT NULL,
    sortOrder INTEGER NOT NULL,
    createdAt TEXT NOT NULL,
    lastUsedAt TEXT NOT NULL,
    PRIMARY KEY(promptItemId, ordinal)
) WITHOUT ROWID;
CREATE INDEX {INDEX_NAME}
ON prompt_item_tags (
    tagKey COLLATE BINARY,
    isFirstOccurrence,
    isDeleted,
    sortOrder ASC,
    createdAt DESC,
    promptItemId ASC
);
"""

ITEM_COLUMNS = (
    "id,title,type,assetKind,modelId,modelName,folderId,folderName,category,"
    "assetPath,thumbnailPath,aspectRatio,width,height,format,fileSize,favorite,"
    "pinnedAt,deletedAt,createdAt,updatedAt,lastUsedAt,sortOrder,tagsJSON,"
    "referencesJSON,description"
)
ITEM_INSERT = f"INSERT INTO prompt_items ({ITEM_COLUMNS}) VALUES ({','.join('?' for _ in ITEM_COLUMNS.split(','))})"
VERSION_INSERT = "INSERT INTO prompt_versions VALUES (?,?,?,?,?,?,?,?)"
RELATION_INSERT = "INSERT INTO prompt_item_tags VALUES (?,?,?,?,?,?,?,?,?)"


def iso(seconds: int) -> str:
    return (dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")


def safe_output_root(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    if "PromptStudio Library" in str(resolved):
        raise ValueError("refusing to write inside the real PromptStudio Library")
    if resolved.parent != PERFORMANCE_ROOT.resolve() or not resolved.name.startswith("phase2a2-"):
        raise ValueError(
            f"phase2a2 fixtures must be under {PERFORMANCE_ROOT}/phase2a2-* (got {resolved})"
        )
    return resolved


def fixture_rows(count: int) -> Iterable[tuple[tuple[Any, ...], tuple[Any, ...], list[tuple[Any, ...]]]]:
    for index in range(count):
        item_id = f"phase2a2-{index:08d}"
        created = iso(index // 5)
        updated = iso(index // 4)
        last_used = iso(index // 7 + 1)
        deleted = iso(index // 9) if index % 17 == 0 else None
        favorite = 1 if index % 5 == 0 else 0
        sort_order = index // 3
        # Include exact-case pairs, an empty name, a special name, and a
        # duplicate occurrence so only isFirstOccurrence=1 yields one card.
        tags = ["Foo" if index % 2 == 0 else "foo"]
        if index % 2 == 0:
            tags.append("Foo")
        if index == 0:
            tags.extend(["", "特/殊 & ?"])
        elif index % 97 == 0:
            tags.append("特/殊 & ?")
        item = (
            item_id,
            f"Phase 2A.2 Fixture {index:08d}",
            ("image", "video", "text", "audio")[index % 4],
            ("image", "video", "markdown", "audio")[index % 4],
            f"model-{index % 20:02d}",
            f"Model {index % 20:02d}",
            f"folder-{index % 32:02d}",
            f"Folder {index % 32:02d}",
            "phase2a2",
            f"assets/{item_id}.dat",
            f"thumbnails/{item_id}.jpg",
            "16:9",
            1920,
            1080,
            "PNG",
            1000 + index,
            favorite,
            None,
            deleted,
            created,
            updated,
            last_used,
            sort_order,
            json.dumps(tags, ensure_ascii=False, separators=(",", ":")),
            "[]",
            "phase2a2 benchmark fixture",
        )
        version = (
            f"version-{index:08d}",
            item_id,
            "1.0",
            "" if index % 11 == 0 else f"Prompt {index}",
            "",
            "{}",
            "",
            created,
        )
        relation_rows = [
            (
                item_id,
                ordinal,
                tag,
                unicodedata.normalize("NFC", tag),
                0 if unicodedata.normalize("NFC", tag) in {
                    unicodedata.normalize("NFC", earlier) for earlier in tags[:ordinal]
                } else 1,
                1 if deleted is not None else 0,
                sort_order,
                created,
                last_used,
            )
            for ordinal, tag in enumerate(tags)
        ]
        yield item, version, relation_rows


def create_database(path: Path, count: int) -> dict[str, Any]:
    if path.exists():
        path.unlink()
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    item_count = 0
    relation_count = 0
    try:
        items: list[tuple[Any, ...]] = []
        versions: list[tuple[Any, ...]] = []
        relations: list[tuple[Any, ...]] = []
        for item, version, relation_rows in fixture_rows(count):
            items.append(item)
            versions.append(version)
            relations.extend(relation_rows)
            if len(items) >= 2_000:
                db.executemany(ITEM_INSERT, items)
                db.executemany(VERSION_INSERT, versions)
                db.executemany(RELATION_INSERT, relations)
                item_count += len(items)
                relation_count += len(relations)
                items.clear()
                versions.clear()
                relations.clear()
        if items:
            db.executemany(ITEM_INSERT, items)
            db.executemany(VERSION_INSERT, versions)
            db.executemany(RELATION_INSERT, relations)
            item_count += len(items)
            relation_count += len(relations)
        db.commit()
        integrity = db.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"integrity_check failed: {integrity}")
        return {
            "itemCount": item_count,
            "relationCount": relation_count,
            "path": str(path),
            "index": INDEX_NAME,
            "schema": "prompt_item_tags(promptItemId,ordinal) WITHOUT ROWID",
        }
    finally:
        db.close()


def tag_page_sql(with_cursor: bool = False) -> str:
    cursor = ""
    if with_cursor:
        cursor = (
            " AND (pit.sortOrder > ? OR (pit.sortOrder = ? AND pit.createdAt < ?)"
            " OR (pit.sortOrder = ? AND pit.createdAt = ? AND pit.promptItemId > ?))"
        )
    return f"""
        SELECT p.id, p.type, p.modelId, p.favorite, p.createdAt, p.sortOrder
        FROM prompt_item_tags pit JOIN prompt_items p ON p.id=pit.promptItemId
        WHERE pit.tagKey=? AND pit.isFirstOccurrence=1 AND pit.isDeleted=0
          AND p.deletedAt IS NULL{cursor}
        ORDER BY pit.sortOrder ASC, pit.createdAt DESC, pit.promptItemId ASC
        LIMIT ?;
    """


COUNT_SQL = """
    SELECT COUNT(*) AS totalCount
    FROM prompt_item_tags pit JOIN prompt_items p ON p.id=pit.promptItemId
    WHERE pit.tagKey=? AND pit.isFirstOccurrence=1 AND pit.isDeleted=0
      AND p.deletedAt IS NULL;
"""


def explain(db: sqlite3.Connection, sql: str, args: tuple[Any, ...]) -> list[str]:
    return [str(row[3]) for row in db.execute("EXPLAIN QUERY PLAN " + sql, args)]


def percentile(values: list[float], rank: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * rank
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def run_pages(db: sqlite3.Connection, pages: int, page_size: int = PAGE_SIZE) -> tuple[int, list[float]]:
    cursor: tuple[Any, ...] | None = None
    total = 0
    timings: list[float] = []
    for _ in range(pages):
        if cursor is None:
            sql = tag_page_sql(False)
            args: tuple[Any, ...] = (TAG_NAME, page_size + 1)
        else:
            sql = tag_page_sql(True)
            sort_order, created_at, item_id = cursor
            args = (TAG_NAME, sort_order, sort_order, created_at, sort_order, created_at, item_id, page_size + 1)
        start = time.perf_counter_ns()
        rows = db.execute(sql, args).fetchall()
        timings.append((time.perf_counter_ns() - start) / 1_000_000)
        visible = rows[:page_size]
        total += len(visible)
        if len(rows) <= page_size:
            break
        last = visible[-1]
        cursor = (last[5], last[4], last[0])
    return total, timings


def benchmark_database(path: Path, repetitions: int) -> dict[str, Any]:
    db = sqlite3.connect(path)
    try:
        db.execute("PRAGMA cache_size=-65536")
        db.execute(f"DROP INDEX IF EXISTS {INDEX_NAME}")
        db.commit()
        before = explain(db, tag_page_sql(False), (TAG_NAME, PAGE_SIZE + 1))
        db.execute(
            f"""CREATE INDEX {INDEX_NAME}
            ON prompt_item_tags (
                tagKey COLLATE BINARY, isFirstOccurrence, isDeleted,
                sortOrder ASC, createdAt DESC, promptItemId ASC
            )"""
        )
        db.commit()
        after = explain(db, tag_page_sql(False), (TAG_NAME, PAGE_SIZE + 1))
        db.execute(COUNT_SQL, (TAG_NAME,)).fetchone()
        first_page_ms: list[float] = []
        ten_page_ms: list[float] = []
        ten_page_rows: list[int] = []
        rss_before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        for _ in range(repetitions):
            total, timings = run_pages(db, 1)
            first_page_ms.extend(timings)
            ten_total, ten_timings = run_pages(db, 10)
            ten_page_rows.append(ten_total)
            ten_page_ms.append(sum(ten_timings))
        rss_after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        return {
            "path": str(path),
            "itemCount": db.execute("SELECT COUNT(*) FROM prompt_items").fetchone()[0],
            "tagCount": db.execute(COUNT_SQL, (TAG_NAME,)).fetchone()[0],
            "index": INDEX_NAME,
            "explainBefore": before,
            "explainAfter": after,
            "firstPage": {
                "p50Ms": percentile(first_page_ms, 0.50),
                "p95Ms": percentile(first_page_ms, 0.95),
                "samples": len(first_page_ms),
            },
            "tenPages": {
                "p50Ms": percentile(ten_page_ms, 0.50),
                "p95Ms": percentile(ten_page_ms, 0.95),
                "rowsPerRun": ten_page_rows,
                "samples": len(ten_page_ms),
            },
            "maxRSSDelta": max(0, rss_after - rss_before),
        }
    finally:
        db.close()


def generate(args: argparse.Namespace) -> None:
    root = safe_output_root(Path(args.output_root))
    root.mkdir(parents=True, exist_ok=True)
    manifest = {"sizes": list(args.sizes), "fixtures": []}
    for size in args.sizes:
        db_path = root / f"library-{size}" / "database" / "promptstudio.sqlite"
        info = create_database(db_path, size)
        fixture_root = db_path.parent.parent
        (fixture_root / "manifest.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
        manifest["fixtures"].append(info)
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


def benchmark(args: argparse.Namespace) -> None:
    root = safe_output_root(Path(args.output_root))
    results = []
    for size in args.sizes:
        path = root / f"library-{size}" / "database" / "promptstudio.sqlite"
        if not path.is_file():
            raise FileNotFoundError(path)
        results.append(benchmark_database(path, args.repetitions))
    output = root / "benchmark-phase2a2.json"
    output.write_text(json.dumps({"results": results}, indent=2) + "\n", encoding="utf-8")
    print(output)
    print(json.dumps({"results": results}, indent=2))


def default_root() -> Path:
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    return PERFORMANCE_ROOT / f"phase2a2-{stamp}"


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("--output-root", default=str(default_root()))
    generate_parser.add_argument("--sizes", nargs="+", type=int, default=list(SIZES))
    generate_parser.set_defaults(func=generate)
    benchmark_parser = subparsers.add_parser("benchmark")
    benchmark_parser.add_argument("--output-root", required=True)
    benchmark_parser.add_argument("--sizes", nargs="+", type=int, default=list(SIZES))
    benchmark_parser.add_argument("--repetitions", type=int, default=5)
    benchmark_parser.set_defaults(func=benchmark)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
