import csv
import importlib.util
import json
import sqlite3
import sys
from pathlib import Path

import pytest


SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "export_review_dataset.py"
SPEC = importlib.util.spec_from_file_location("export_review_dataset", SCRIPT_PATH)
export_review_dataset = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = export_review_dataset
SPEC.loader.exec_module(export_review_dataset)


def create_database(project_root: Path) -> None:
    project_root.mkdir()
    connection = sqlite3.connect(project_root / "project.db")
    connection.executescript(
        """
        CREATE TABLE videos (id TEXT PRIMARY KEY);
        CREATE TABLE candidates (
            id TEXT PRIMARY KEY,
            video_id TEXT NOT NULL,
            event_time_ms INTEGER NOT NULL,
            review_start_ms INTEGER NOT NULL,
            review_end_ms INTEGER NOT NULL,
            detector_version TEXT NOT NULL,
            score REAL,
            confidence TEXT,
            evidence_json TEXT NOT NULL DEFAULT '{}'
        );
        CREATE TABLE candidate_reviews (
            candidate_id TEXT PRIMARY KEY,
            status TEXT NOT NULL DEFAULT 'pending',
            reason TEXT,
            note TEXT,
            reviewed_at TEXT
        );
        INSERT INTO videos (id) VALUES ('video-1');
        INSERT INTO candidates VALUES
            ('goal-1', 'video-1', 1000, 500, 1500, 'detector-v1', 0.91, 'high', '{"source":"rim"}'),
            ('pending-1', 'video-1', 2000, 1500, 2500, 'detector-v1', 0.42, 'review', '{"source":"motion"}'),
            ('bad-json-1', 'video-1', 3000, 2500, 3500, 'detector-v2', 0.30, 'low', '{not-json');
        INSERT INTO candidate_reviews VALUES
            ('goal-1', 'goal', 'pass_ball', '人工确认', '2026-08-07T01:02:03.000+00:00'),
            ('pending-1', 'pending', NULL, NULL, NULL),
            ('bad-json-1', 'excluded', 'rebound', '篮板', '2026-08-07T02:03:04.000+00:00');
        """
    )
    connection.commit()
    connection.close()


def test_export_filters_pending_and_preserves_stable_fields(tmp_path: Path):
    project_root = tmp_path / "project"
    create_database(project_root)

    result = export_review_dataset.export_dataset(project_root, timestamp="20260807T000000Z")

    assert result.jsonl_path.name == "review_dataset_20260807T000000Z.jsonl"
    assert result.csv_path is None
    rows = [json.loads(line) for line in result.jsonl_path.read_text(encoding="utf-8").splitlines()]
    assert [row["candidate_id"] for row in rows] == ["goal-1", "bad-json-1"]
    assert list(rows[0]) == list(export_review_dataset.EXPORT_FIELDS)
    assert rows[0]["model_score"] == 0.91
    assert rows[0]["model_confidence"] == "high"
    assert rows[0]["review_reason"] == "pass_ball"
    assert rows[0]["review_note"] == "人工确认"
    assert rows[0]["evidence_json"] == {"source": "rim"}
    assert rows[0]["evidence_parse_error"] is None


def test_include_pending_and_csv_use_same_fields(tmp_path: Path):
    project_root = tmp_path / "project"
    create_database(project_root)

    result = export_review_dataset.export_dataset(
        project_root,
        output_dir=tmp_path / "exports",
        include_pending=True,
        include_csv=True,
        timestamp="20260807T000001Z",
    )

    assert [row["candidate_id"] for row in result.rows] == ["goal-1", "pending-1", "bad-json-1"]
    with result.csv_path.open(newline="", encoding="utf-8") as handle:
        csv_rows = list(csv.DictReader(handle))
    assert csv_rows[1]["candidate_id"] == "pending-1"
    assert list(csv_rows[0]) == list(export_review_dataset.EXPORT_FIELDS)


def test_bad_json_is_retained_as_string_with_parse_error(tmp_path: Path):
    project_root = tmp_path / "project"
    create_database(project_root)

    result = export_review_dataset.export_dataset(project_root, timestamp="20260807T000002Z")
    row = result.rows[1]

    assert row["evidence_json"] == "{not-json"
    assert row["evidence_parse_error"]


def test_invalid_project_path_does_not_create_database(tmp_path: Path):
    missing_root = tmp_path / "missing-project"

    with pytest.raises(FileNotFoundError):
        export_review_dataset.export_dataset(missing_root)

    assert not missing_root.exists()


def test_existing_output_is_rejected(tmp_path: Path):
    project_root = tmp_path / "project"
    create_database(project_root)
    output_dir = tmp_path / "exports"
    output_dir.mkdir()
    (output_dir / "review_dataset_20260807T000003Z.jsonl").write_text("existing\n", encoding="utf-8")

    with pytest.raises(FileExistsError):
        export_review_dataset.export_dataset(
            project_root,
            output_dir=output_dir,
            timestamp="20260807T000003Z",
        )
