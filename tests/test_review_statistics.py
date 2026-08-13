import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore


def _create_project(tmp_path: Path) -> tuple[EngineService, ProjectStore, Path]:
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "审核统计", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    return service, store, project_root


def _candidate(candidate_id: str, video_id: str, evidence: dict | None = None) -> dict:
    return {
        "id": candidate_id,
        "video_id": video_id,
        "event_time_ms": int(candidate_id.rsplit("-", 1)[-1]),
        "default_start_ms": 0,
        "default_end_ms": 4000,
        "review_start_ms": 0,
        "review_end_ms": 4000,
        "detector_version": "test",
        "score": 0.8,
        "confidence": "review",
        "evidence_json": json.dumps(evidence or {}, ensure_ascii=False),
    }


def _add_candidates(store: ProjectStore, tmp_path: Path, count: int = 3) -> list[dict]:
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    rows = [_candidate(f"candidate-{index}", video["id"]) for index in range(count)]
    store.replace_candidates(video["id"], rows)
    return rows


def test_legacy_candidate_reviews_migrate_without_data_loss(tmp_path: Path):
    project_root = tmp_path / "legacy"
    project_root.mkdir()
    db_path = project_root / "project.db"
    with sqlite3.connect(db_path) as connection:
        connection.execute(
            """
            CREATE TABLE candidate_reviews (
                candidate_id TEXT PRIMARY KEY,
                status TEXT NOT NULL DEFAULT 'pending',
                note TEXT,
                reviewed_at TEXT,
                updated_at TEXT NOT NULL
            )
            """
        )
        connection.execute(
            "INSERT INTO candidate_reviews (candidate_id, status, note, reviewed_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            ("legacy-candidate", "goal", "旧记录", "2026-08-07T00:00:00+00:00", "2026-08-07T00:00:00+00:00"),
        )

    store = ProjectStore(project_root)
    store.initialize()

    with sqlite3.connect(db_path) as connection:
        columns = {
            row[1]
            for row in connection.execute("PRAGMA table_info(candidate_reviews)").fetchall()
        }
        row = connection.execute(
            "SELECT status, note, review_started_at, review_duration_ms FROM candidate_reviews WHERE candidate_id = ?",
            ("legacy-candidate",),
        ).fetchone()

    assert {"reason", "review_started_at", "review_duration_ms"}.issubset(columns)
    assert row == ("goal", "旧记录", None, None)


def test_review_start_and_submit_persist_non_negative_duration(tmp_path: Path):
    service, store, project_root = _create_project(tmp_path)
    rows = _add_candidates(store, tmp_path, count=3)
    started_at = (datetime.now(timezone.utc) - timedelta(seconds=1.2)).isoformat(timespec="milliseconds")
    future_started_at = (datetime.now(timezone.utc) + timedelta(seconds=10)).isoformat(timespec="milliseconds")

    result = service.handle("start_review", {
        "project_root": str(project_root),
        "candidate_id": rows[0]["id"],
        "review_started_at": started_at,
    })
    service.handle("review_candidate", {
        "project_root": str(project_root),
        "candidate_id": rows[0]["id"],
        "status": "goal",
    })
    service.handle("review_candidate", {
        "project_root": str(project_root),
        "candidate_id": rows[1]["id"],
        "status": "excluded",
    })
    service.handle("review_candidate", {
        "project_root": str(project_root),
        "candidate_id": rows[2]["id"],
        "status": "excluded",
        "review_started_at": future_started_at,
    })

    with store.connect() as connection:
        reviews = {
            row["candidate_id"]: dict(row)
            for row in connection.execute(
                "SELECT candidate_id, review_started_at, review_duration_ms FROM candidate_reviews"
            ).fetchall()
        }

    assert result["review_started_at"] == started_at
    assert reviews[rows[0]["id"]]["review_started_at"] == started_at
    assert reviews[rows[0]["id"]]["review_duration_ms"] >= 1000
    assert reviews[rows[1]["id"]]["review_duration_ms"] == 0
    assert reviews[rows[2]["id"]]["review_duration_ms"] == 0
    assert all(review["review_duration_ms"] >= 0 for review in reviews.values())


def test_review_note_update_preserves_completed_review_duration(tmp_path: Path):
    service, store, project_root = _create_project(tmp_path)
    rows = _add_candidates(store, tmp_path, count=1)
    started_at = (datetime.now(timezone.utc) - timedelta(seconds=1.2)).isoformat(timespec="milliseconds")
    payload = {
        "project_root": str(project_root),
        "candidate_id": rows[0]["id"],
    }

    service.handle("start_review", {**payload, "review_started_at": started_at})
    service.handle("review_candidate", {**payload, "status": "goal"})
    with store.connect() as connection:
        before = connection.execute(
            "SELECT review_started_at, review_duration_ms FROM candidate_reviews WHERE candidate_id = ?",
            (rows[0]["id"],),
        ).fetchone()

    service.handle("review_candidate", {**payload, "status": "goal", "note": "补篮"})
    with store.connect() as connection:
        after = connection.execute(
            "SELECT review_started_at, review_duration_ms FROM candidate_reviews WHERE candidate_id = ?",
            (rows[0]["id"],),
        ).fetchone()

    assert after == before


def test_get_statistics_returns_review_metrics_and_conflicts(tmp_path: Path):
    service, store, project_root = _create_project(tmp_path)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    rows = [
        _candidate("candidate-1", video["id"], {"gates": {"evidence_conflict": True}}),
        _candidate("candidate-2", video["id"]),
        _candidate("candidate-3", video["id"]),
    ]
    store.replace_candidates(video["id"], rows)
    started_at = (datetime.now(timezone.utc) - timedelta(seconds=1.2)).isoformat(timespec="milliseconds")
    service.handle("start_review", {
        "project_root": str(project_root),
        "candidate_id": rows[0]["id"],
        "review_started_at": started_at,
    })
    service.handle("review_candidate", {
        "project_root": str(project_root),
        "candidate_id": rows[0]["id"],
        "status": "goal",
    })
    service.handle("review_candidate", {
        "project_root": str(project_root),
        "candidate_id": rows[1]["id"],
        "status": "excluded",
        "reason": "rebound",
    })

    statistics = service.handle("get_statistics", {"project_root": str(project_root)})["statistics"]

    assert statistics["reviewed_count"] == 2
    assert statistics["goal_count"] == 1
    assert statistics["excluded_count"] == 1
    assert statistics["pending_count"] == 1
    assert statistics["confirmation_rate"] == pytest.approx(0.5)
    assert statistics["avg_review_duration_ms"] >= 0
    assert statistics["reason_distribution"] == {"rebound": 1}
    assert statistics["conflict_count"] == 1


def test_players_can_be_created_assigned_and_cleared(tmp_path: Path):
    service, store, project_root = _create_project(tmp_path)
    rows = _add_candidates(store, tmp_path, count=2)

    created = service.handle("create_player", {
        "project_root": str(project_root),
        "name": "科比",
    })["player"]
    service.handle("set_candidate_player", {
        "project_root": str(project_root),
        "candidate_id": rows[0]["id"],
        "player_id": created["id"],
    })
    service.handle("set_candidates_player", {
        "project_root": str(project_root),
        "candidate_ids": [rows[1]["id"]],
        "player_id": created["id"],
    })

    candidates = service.handle("list_candidates", {
        "project_root": str(project_root),
        "video_id": rows[0]["video_id"],
    })["candidates"]
    assert [item["player_name"] for item in candidates] == ["科比", "科比"]

    service.handle("set_candidate_player", {
        "project_root": str(project_root),
        "candidate_id": rows[0]["id"],
        "player_id": None,
    })
    candidates = store.list_candidates(rows[0]["video_id"])
    assert candidates[0]["player_id"] is None
    assert candidates[1]["player_id"] == created["id"]

    deleted = service.handle("delete_player", {
        "project_root": str(project_root),
        "player_id": created["id"],
    })
    assert deleted["deleted"] is True
    candidates = store.list_candidates(rows[0]["video_id"])
    assert all(item["player_id"] is None for item in candidates)
    assert store.list_players() == []


def test_export_snapshot_filters_by_player_and_unassigned(tmp_path: Path, monkeypatch):
    service, store, project_root = _create_project(tmp_path)
    rows = _add_candidates(store, tmp_path, count=3)
    player = service.handle("create_player", {
        "project_root": str(project_root),
        "name": "罗斯",
    })["player"]
    service.handle("set_candidate_player", {
        "project_root": str(project_root),
        "candidate_id": rows[0]["id"],
        "player_id": player["id"],
    })

    monkeypatch.setattr(service, "_validated_source", lambda video: tmp_path / "source.mp4")
    monkeypatch.setattr(service, "_ensure_disk_space", lambda *_: None)
    result = service.handle("start_export", {
        "project_root": str(project_root),
        "video_id": rows[0]["video_id"],
        "player_ids": [player["id"]],
        "include_unassigned": False,
    })
    checkpoint = store.get_job(result["job"]["id"])["checkpoint_json"]
    snapshot = json.loads(checkpoint)["candidate_snapshot"]
    assert [item["id"] for item in snapshot] == [rows[0]["id"]]
