from __future__ import annotations

import argparse
import csv
import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


EXPORT_FIELDS = (
    "candidate_id",
    "video_id",
    "event_time_ms",
    "review_start_ms",
    "review_end_ms",
    "model_score",
    "model_confidence",
    "detector_version",
    "review_status",
    "review_reason",
    "review_note",
    "reviewed_at",
    "evidence_json",
    "evidence_parse_error",
)
REVIEWED_STATUSES = ("goal", "excluded", "deferred", "second_review")


@dataclass(frozen=True)
class ExportResult:
    jsonl_path: Path
    csv_path: Path | None
    rows: list[dict[str, Any]]


def _database_path(project_root: str | Path) -> Path:
    root = Path(project_root).expanduser().resolve()
    if not root.exists():
        raise FileNotFoundError(f"Project root does not exist: {root}")
    if not root.is_dir():
        raise NotADirectoryError(f"Project root is not a directory: {root}")
    database = root / "project.db"
    if not database.is_file():
        raise FileNotFoundError(f"SQLite database does not exist: {database}")
    return database


def _parse_evidence(raw: str) -> tuple[Any, str | None]:
    try:
        return json.loads(raw), None
    except (TypeError, json.JSONDecodeError) as exc:
        return raw, f"{type(exc).__name__}: {exc}"


def _load_rows(project_root: str | Path, include_pending: bool) -> list[dict[str, Any]]:
    database = _database_path(project_root)
    status_filter = "" if include_pending else "WHERE COALESCE(r.status, 'pending') IN (?, ?, ?, ?)"
    params: tuple[str, ...] = () if include_pending else REVIEWED_STATUSES
    query = f"""
        SELECT
            c.id AS candidate_id,
            c.video_id,
            c.event_time_ms,
            c.review_start_ms,
            c.review_end_ms,
            c.score AS model_score,
            c.confidence AS model_confidence,
            c.detector_version,
            COALESCE(r.status, 'pending') AS review_status,
            r.reason AS review_reason,
            r.note AS review_note,
            r.reviewed_at,
            c.evidence_json
        FROM candidates AS c
        LEFT JOIN candidate_reviews AS r ON r.candidate_id = c.id
        {status_filter}
        ORDER BY c.event_time_ms, c.id
    """
    try:
        with sqlite3.connect(database) as connection:
            connection.row_factory = sqlite3.Row
            database_rows = connection.execute(query, params).fetchall()
    except sqlite3.DatabaseError as exc:
        raise ValueError(f"Invalid SQLite database: {database}") from exc

    rows = []
    for database_row in database_rows:
        row = dict(database_row)
        evidence, parse_error = _parse_evidence(row.pop("evidence_json"))
        row["evidence_json"] = evidence
        row["evidence_parse_error"] = parse_error
        rows.append({field: row.get(field) for field in EXPORT_FIELDS})
    return rows


def _csv_row(row: dict[str, Any]) -> dict[str, Any]:
    value = row["evidence_json"]
    if isinstance(value, (dict, list, tuple, int, float, bool)) or value is None:
        value = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return {field: value if field == "evidence_json" else row[field] for field in EXPORT_FIELDS}


def export_dataset(
    project_root: str | Path,
    output_dir: str | Path | None = None,
    include_pending: bool = False,
    include_csv: bool = False,
    timestamp: str | None = None,
) -> ExportResult:
    root = Path(project_root).expanduser().resolve()
    rows = _load_rows(root, include_pending)
    destination = (
        Path(output_dir).expanduser().resolve()
        if output_dir is not None
        else root / "artifacts" / "exports"
    )
    destination.mkdir(parents=True, exist_ok=True)
    stamp = timestamp or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    jsonl_path = destination / f"review_dataset_{stamp}.jsonl"
    csv_path = destination / f"review_dataset_{stamp}.csv" if include_csv else None
    paths = [jsonl_path] + ([csv_path] if csv_path else [])
    existing = [path for path in paths if path.exists()]
    if existing:
        raise FileExistsError("Refusing to overwrite existing output: " + ", ".join(map(str, existing)))

    with jsonl_path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")

    if csv_path is not None:
        with csv_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=EXPORT_FIELDS)
            writer.writeheader()
            writer.writerows(_csv_row(row) for row in rows)
    return ExportResult(jsonl_path=jsonl_path, csv_path=csv_path, rows=rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export manually reviewed basketball candidates as training data.")
    parser.add_argument("project_root", help="Project root containing project.db")
    parser.add_argument("--output-dir", help="Output directory; defaults to project_root/artifacts/exports")
    parser.add_argument("--include-pending", action="store_true", help="Include pending candidates")
    parser.add_argument("--csv", action="store_true", dest="include_csv", help="Also write a CSV file")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    result = export_dataset(
        args.project_root,
        output_dir=args.output_dir,
        include_pending=args.include_pending,
        include_csv=args.include_csv,
    )
    print(f"candidates={len(result.rows)}")
    print(f"jsonl={result.jsonl_path}")
    if result.csv_path:
        print(f"csv={result.csv_path}")


if __name__ == "__main__":
    main()
