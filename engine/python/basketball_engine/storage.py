from __future__ import annotations

import json
import math
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable
from uuid import uuid4


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid4().hex}"


def normalize_review_started_at(value: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("INVALID_REVIEW_STARTED_AT")
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("INVALID_REVIEW_STARTED_AT") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat(timespec="milliseconds")


def review_duration_ms(started_at: str | None, finished_at: str) -> int:
    if not started_at:
        return 0
    try:
        started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
        finished = datetime.fromisoformat(finished_at.replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        return 0
    if started.tzinfo is None:
        started = started.replace(tzinfo=timezone.utc)
    if finished.tzinfo is None:
        finished = finished.replace(tzinfo=timezone.utc)
    return max(0, int((finished - started).total_seconds() * 1000))


def has_evidence_conflict(evidence_json: str | None) -> bool:
    try:
        evidence = json.loads(evidence_json or "{}")
    except (TypeError, json.JSONDecodeError):
        return False
    if not isinstance(evidence, dict):
        return False
    truthy = lambda value: value is True or str(value).lower() == "true"
    if truthy(evidence.get("evidence_conflict")) or truthy(evidence.get("conflict")):
        return True
    gates = evidence.get("gates") if isinstance(evidence.get("gates"), dict) else {}
    if truthy(gates.get("evidence_conflict")) or truthy(gates.get("signal_conflict")):
        return True
    signals = evidence.get("signals") if isinstance(evidence.get("signals"), dict) else {}
    try:
        net_score = float(signals["net_score"])
        audio_score = float(signals["audio_score"])
    except (KeyError, TypeError, ValueError):
        return False
    return (net_score >= 0.55) != (audio_score >= 0.65)


class ProjectStore:
    def __init__(self, root_path: str | Path):
        self.root = Path(root_path).expanduser().resolve()
        self.db_path = self.root / "project.db"

    def initialize(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        for name in ("artifacts/proxies", "artifacts/detections", "artifacts/review_clips", "artifacts/exports", "logs", "telemetry_outbox"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        schema_path = Path(__file__).resolve().parents[3] / "docs/architecture/SQLITE_SCHEMA_V1.sql"
        with sqlite3.connect(self.db_path, timeout=30.0) as connection:
            connection.execute("PRAGMA foreign_keys = ON")
            connection.execute("PRAGMA busy_timeout = 30000")
            connection.executescript(schema_path.read_text(encoding="utf-8"))
            self._ensure_schema_compatibility(connection)

    @staticmethod
    def _ensure_schema_compatibility(connection: sqlite3.Connection) -> None:
        columns = {
            row[1]
            for row in connection.execute("PRAGMA table_info(candidate_reviews)").fetchall()
        }
        for name, definition in (
            ("reason", "TEXT"),
            ("review_started_at", "TEXT"),
            ("review_duration_ms", "INTEGER"),
        ):
            if name not in columns:
                connection.execute(f"ALTER TABLE candidate_reviews ADD COLUMN {name} {definition}")

    def connect(self) -> sqlite3.Connection:
        if not self.db_path.exists():
            self.initialize()
        connection = sqlite3.connect(self.db_path, timeout=30.0)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 30000")
        self._ensure_schema_compatibility(connection)
        return connection

    def create_project(self, project_id: str, name: str, language: str = "zh-CN") -> Dict[str, Any]:
        timestamp = now_iso()
        with self.connect() as connection:
            connection.execute(
                "INSERT INTO projects (id, name, root_path, language, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                (project_id, name, str(self.root), language, timestamp, timestamp),
            )
        return {"id": project_id, "name": name, "root_path": str(self.root), "language": language}

    def project(self) -> Dict[str, Any] | None:
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM projects LIMIT 1").fetchone()
        return dict(row) if row else None

    def update_project_settings(
        self,
        project_id: str,
        name: str | None = None,
        theme_mode: str | None = None,
    ) -> Dict[str, Any]:
        if name is not None and not name.strip():
            raise ValueError("PROJECT_NAME_INVALID")
        if theme_mode is not None and theme_mode not in {"system", "light", "dark"}:
            raise ValueError("THEME_MODE_INVALID")
        fields = ["updated_at = ?"]
        values: list[Any] = [now_iso()]
        if name is not None:
            fields.append("name = ?")
            values.append(name.strip())
        if theme_mode is not None:
            fields.append("theme_mode = ?")
            values.append(theme_mode)
        values.append(project_id)
        with self.connect() as connection:
            cursor = connection.execute(
                f"UPDATE projects SET {', '.join(fields)} WHERE id = ?",
                values,
            )
            if cursor.rowcount != 1:
                raise LookupError("PROJECT_NOT_FOUND")
        project = self.project()
        if not project:
            raise LookupError("PROJECT_NOT_FOUND")
        return project

    def latest_video(self) -> Dict[str, Any] | None:
        with self.connect() as connection:
            row = connection.execute(
                "SELECT * FROM videos ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
        return dict(row) if row else None

    def context(self) -> Dict[str, Any]:
        project = self.project()
        if not project:
            raise ValueError("PROJECT_NOT_FOUND")
        video = self.latest_video()
        if video:
            video = dict(video)
            source = Path(video["source_path"])
            video["source_exists"] = source.is_file()
            video["source_status"] = "linked" if source.is_file() else "missing"
        roi = self.active_roi(video["id"]) if video else None
        return {
            "database_path": str(self.db_path),
            "project_root": str(self.root),
            "project": project,
            "video": video,
            "roi": roi,
            "statistics": self.statistics(),
        }

    def link_video(self, metadata: Dict[str, Any]) -> Dict[str, Any]:
        project = self.project()
        if not project:
            raise ValueError("PROJECT_NOT_INITIALIZED")
        video_id = metadata.get("id") or new_id("video")
        timestamp = now_iso()
        values = (
            video_id,
            project["id"],
            metadata["source_path"],
            metadata["source_size_bytes"],
            metadata["source_mtime_ns"],
            metadata.get("duration_ms"),
            metadata.get("width"),
            metadata.get("height"),
            metadata.get("fps"),
            metadata.get("video_codec"),
            metadata.get("audio_codec"),
            timestamp,
            timestamp,
        )
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO videos (
                    id, project_id, source_path, source_size_bytes, source_mtime_ns,
                    duration_ms, width, height, fps, video_codec, audio_codec,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                values,
            )
        return {"id": video_id, **metadata}

    def video(self, video_id: str) -> Dict[str, Any] | None:
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM videos WHERE id = ?", (video_id,)).fetchone()
        return dict(row) if row else None

    def relink_video(self, video_id: str, metadata: Dict[str, Any]) -> Dict[str, Any]:
        """Replace only the external source reference; keep candidates and reviews."""
        source_path = metadata.get("source_path")
        if not isinstance(source_path, str) or not source_path.strip():
            raise ValueError("VIDEO_PATH_INVALID")
        timestamp = now_iso()
        with self.connect() as connection:
            cursor = connection.execute(
                """
                UPDATE videos SET
                    source_path = ?, source_size_bytes = ?, source_mtime_ns = ?,
                    duration_ms = ?, width = ?, height = ?, fps = ?,
                    video_codec = ?, audio_codec = ?, status = 'linked', updated_at = ?
                WHERE id = ?
                """,
                (
                    source_path,
                    metadata["source_size_bytes"],
                    metadata["source_mtime_ns"],
                    metadata.get("duration_ms"),
                    metadata.get("width"),
                    metadata.get("height"),
                    metadata.get("fps"),
                    metadata.get("video_codec"),
                    metadata.get("audio_codec"),
                    timestamp,
                    video_id,
                ),
            )
            if cursor.rowcount != 1:
                raise LookupError("VIDEO_NOT_FOUND")
        video = self.video(video_id)
        if not video:
            raise LookupError("VIDEO_NOT_FOUND")
        video["source_exists"] = True
        video["source_status"] = "linked"
        return video

    def save_roi(self, video_id: str, roi: Dict[str, Any]) -> Dict[str, Any]:
        video = self.video(video_id)
        if not video:
            raise LookupError("VIDEO_NOT_FOUND")
        try:
            coordinates = {key: float(roi[key]) for key in ("x1", "y1", "x2", "y2")}
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError("ROI_COORDINATES_INVALID") from exc
        if not all(math.isfinite(value) for value in coordinates.values()):
            raise ValueError("ROI_COORDINATES_INVALID")
        if coordinates["x1"] < 0 or coordinates["y1"] < 0:
            raise ValueError("ROI_COORDINATES_INVALID")
        if coordinates["x2"] <= coordinates["x1"] or coordinates["y2"] <= coordinates["y1"]:
            raise ValueError("ROI_COORDINATES_INVALID")
        if video.get("width") and coordinates["x2"] > float(video["width"]):
            raise ValueError("ROI_OUT_OF_BOUNDS")
        if video.get("height") and coordinates["y2"] > float(video["height"]):
            raise ValueError("ROI_OUT_OF_BOUNDS")
        if video.get("width") and video.get("height"):
            roi_width = coordinates["x2"] - coordinates["x1"]
            roi_height = coordinates["y2"] - coordinates["y1"]
            min_width = max(64.0, float(video["width"]) * 0.08)
            min_height = max(96.0, float(video["height"]) * 0.12)
            if roi_width < min_width or roi_height < min_height:
                raise ValueError(
                    f"ROI_TOO_SMALL: 检测区域至少需要约 {round(min_width)}×{round(min_height)} 像素"
                )
        roi_id = roi.get("id") or new_id("roi")
        timestamp = now_iso()
        calibration = json.dumps(roi.get("calibration", {}), ensure_ascii=False)
        with self.connect() as connection:
            connection.execute("UPDATE rois SET is_active = 0 WHERE video_id = ?", (video_id,))
            connection.execute(
                """
                INSERT INTO rois (id, video_id, name, x1, y1, x2, y2, calibration_json, is_active, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
                (
                    roi_id,
                    video_id,
                    roi.get("name", "Hoop 1"),
                    coordinates["x1"],
                    coordinates["y1"],
                    coordinates["x2"],
                    coordinates["y2"],
                    calibration,
                    timestamp,
                    timestamp,
                ),
            )
        return {"id": roi_id, "video_id": video_id, **roi}

    def active_roi(self, video_id: str) -> Dict[str, Any] | None:
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM rois WHERE video_id = ? AND is_active = 1 LIMIT 1", (video_id,)).fetchone()
        if not row:
            return None
        value = dict(row)
        value["calibration"] = json.loads(value.pop("calibration_json"))
        return value

    def list_candidates(self, video_id: str | None = None) -> list[Dict[str, Any]]:
        query = """
            SELECT c.*, COALESCE(r.status, 'pending') AS review_status,
                   CASE WHEN COALESCE(r.status, 'pending') = 'excluded'
                        THEN 'excluded' ELSE 'included' END AS selection_status,
                   r.reason AS review_reason, r.note, r.reviewed_at,
                   r.review_started_at, r.review_duration_ms
            FROM candidates c
            LEFT JOIN candidate_reviews r ON r.candidate_id = c.id
        """
        params: Iterable[Any] = ()
        if video_id:
            query += " WHERE c.video_id = ?"
            params = (video_id,)
        query += " ORDER BY c.event_time_ms"
        with self.connect() as connection:
            return [dict(row) for row in connection.execute(query, tuple(params)).fetchall()]

    def replace_candidates(self, video_id: str, rows: list[Dict[str, Any]]) -> None:
        timestamp = now_iso()
        with self.connect() as connection:
            existing_reviews = {
                row["candidate_id"]: dict(row)
                for row in connection.execute(
                    "SELECT candidate_id, status, reason, note, reviewed_at, review_started_at, review_duration_ms "
                    "FROM candidate_reviews "
                    "WHERE candidate_id IN (SELECT id FROM candidates WHERE video_id = ?)",
                    (video_id,),
                ).fetchall()
            }
            connection.execute("DELETE FROM candidates WHERE video_id = ?", (video_id,))
            for row in rows:
                connection.execute(
                    """
                    INSERT INTO candidates (
                        id, video_id, roi_id, group_id, event_time_ms,
                        default_start_ms, default_end_ms, review_start_ms, review_end_ms,
                        detector_version, score, confidence, evidence_json, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        row["id"],
                        video_id,
                        row.get("roi_id"),
                        row.get("group_id"),
                        int(row["event_time_ms"]),
                        int(row["default_start_ms"]),
                        int(row["default_end_ms"]),
                        int(row.get("review_start_ms", row["default_start_ms"])),
                        int(row.get("review_end_ms", row["default_end_ms"])),
                        row.get("detector_version", "unknown"),
                        row.get("score"),
                        row.get("confidence", "pending"),
                        row.get("evidence_json", "{}"),
                        row.get("created_at", timestamp),
                        row.get("updated_at", timestamp),
                    ),
                )
                review = existing_reviews.get(row["id"])
                connection.execute(
                    """
                    INSERT INTO candidate_reviews (
                        candidate_id, status, reason, note, reviewed_at,
                        review_started_at, review_duration_ms, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        row["id"],
                        review["status"] if review else "pending",
                        review["reason"] if review else None,
                        review["note"] if review else None,
                        review["reviewed_at"] if review else None,
                        review["review_started_at"] if review else None,
                        review["review_duration_ms"] if review else None,
                        timestamp,
                    ),
                )

    def start_review(self, candidate_id: str, review_started_at: str | None = None) -> str:
        timestamp = normalize_review_started_at(review_started_at) if review_started_at is not None else now_iso()
        with self.connect() as connection:
            if not connection.execute("SELECT 1 FROM candidates WHERE id = ?", (candidate_id,)).fetchone():
                raise LookupError("CANDIDATE_NOT_FOUND")
            cursor = connection.execute(
                """
                UPDATE candidate_reviews
                SET review_started_at = ?, review_duration_ms = NULL, updated_at = ?
                WHERE candidate_id = ?
                """,
                (timestamp, now_iso(), candidate_id),
            )
            if cursor.rowcount != 1:
                connection.execute(
                    """
                    INSERT INTO candidate_reviews (
                        candidate_id, status, review_started_at, review_duration_ms, updated_at
                    ) VALUES (?, 'pending', ?, NULL, ?)
                    """,
                    (candidate_id, timestamp, now_iso()),
                )
        return timestamp

    def review_candidate(
        self,
        candidate_id: str,
        status: str,
        note: str | None = None,
        reason: str | None = None,
        review_started_at: str | None = None,
    ) -> None:
        if status not in {"pending", "goal", "excluded", "deferred", "second_review"}:
            raise ValueError("INVALID_REVIEW_STATUS")
        if reason is not None and reason not in {
            "pass_ball",
            "no_shot",
            "rim_out",
            "rebound",
            "net_no_motion",
            "duplicate",
            "uncertain",
            "other",
        }:
            raise ValueError("INVALID_REVIEW_REASON")
        timestamp = now_iso()
        with self.connect() as connection:
            candidate = connection.execute(
                """
                SELECT c.id, v.project_id, r.review_started_at, r.review_duration_ms
                FROM candidates c
                JOIN videos v ON v.id = c.video_id
                LEFT JOIN candidate_reviews r ON r.candidate_id = c.id
                WHERE c.id = ?
                """,
                (candidate_id,),
            ).fetchone()
            if not candidate:
                raise LookupError("CANDIDATE_NOT_FOUND")
            explicit_started_at = (
                normalize_review_started_at(review_started_at)
                if review_started_at is not None
                else None
            )
            if explicit_started_at is not None:
                effective_started_at = explicit_started_at
                duration = review_duration_ms(effective_started_at, timestamp)
            elif candidate["review_duration_ms"] is not None:
                effective_started_at = candidate["review_started_at"]
                duration = max(0, int(candidate["review_duration_ms"]))
            else:
                effective_started_at = candidate["review_started_at"] or timestamp
                duration = review_duration_ms(effective_started_at, timestamp)
            connection.execute(
                """
                INSERT INTO candidate_reviews (
                    candidate_id, status, reason, note, reviewed_at,
                    review_started_at, review_duration_ms, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(candidate_id) DO UPDATE SET
                    status = excluded.status,
                    reason = excluded.reason,
                    note = excluded.note,
                    reviewed_at = excluded.reviewed_at,
                    review_started_at = excluded.review_started_at,
                    review_duration_ms = excluded.review_duration_ms,
                    updated_at = excluded.updated_at
                """,
                (candidate_id, status, reason, note, timestamp, effective_started_at, duration, timestamp),
            )
            connection.execute(
                """
                INSERT INTO audit_events (id, project_id, event_type, payload_json, created_at)
                VALUES (?, ?, 'review_candidate', ?, ?)
                """,
                (
                    new_id("audit"),
                    candidate["project_id"],
                    json.dumps(
                        {
                            "candidate_id": candidate_id,
                            "status": status,
                            "reason": reason,
                            "note": note,
                            "review_started_at": effective_started_at,
                            "review_duration_ms": duration,
                        },
                        ensure_ascii=False,
                    ),
                    timestamp,
                ),
            )

    def list_review_history(self, candidate_id: str) -> list[Dict[str, Any]]:
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT payload_json, created_at
                FROM audit_events
                WHERE event_type = 'review_candidate'
                ORDER BY created_at, id
                """
            ).fetchall()
        history: list[Dict[str, Any]] = []
        for row in rows:
            try:
                payload = json.loads(row["payload_json"])
            except (TypeError, json.JSONDecodeError):
                continue
            if not isinstance(payload, dict) or payload.get("candidate_id") != candidate_id:
                continue
            history.append(
                {
                    "candidate_id": candidate_id,
                    "status": payload.get("status"),
                    "reason": payload.get("reason"),
                    "note": payload.get("note"),
                    "reviewed_at": row["created_at"],
                    "review_started_at": payload.get("review_started_at"),
                    "review_duration_ms": payload.get("review_duration_ms"),
                }
            )
        return history

    def update_clip_range(self, candidate_id: str, start_ms: int, end_ms: int) -> None:
        if start_ms < 0 or end_ms <= start_ms:
            raise ValueError("INVALID_CLIP_RANGE")
        with self.connect() as connection:
            row = connection.execute(
                """
                SELECT c.id, v.duration_ms
                FROM candidates c
                JOIN videos v ON v.id = c.video_id
                WHERE c.id = ?
                """,
                (candidate_id,),
            ).fetchone()
            if not row:
                raise LookupError("CANDIDATE_NOT_FOUND")
            if row["duration_ms"] is not None and end_ms > int(row["duration_ms"]):
                raise ValueError("INVALID_CLIP_RANGE")
            cursor = connection.execute(
                "UPDATE candidates SET review_start_ms = ?, review_end_ms = ?, updated_at = ? WHERE id = ?",
                (start_ms, end_ms, now_iso(), candidate_id),
            )

    def create_job(self, project_id: str, video_id: str | None, job_type: str, checkpoint: Dict[str, Any] | None = None) -> Dict[str, Any]:
        job_id = new_id("job")
        timestamp = now_iso()
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO jobs (id, project_id, video_id, type, state, stage, checkpoint_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, 'queued', 'validate_input', ?, ?, ?)
                """,
                (job_id, project_id, video_id, job_type, json.dumps(checkpoint or {}, ensure_ascii=False), timestamp, timestamp),
            )
        return {"id": job_id, "state": "queued", "stage": "validate_input", "progress": 0.0}

    def get_job(self, job_id: str) -> Dict[str, Any] | None:
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return dict(row) if row else None

    def list_jobs(
        self,
        project_id: str,
        job_type: str | None = None,
        states: Iterable[str] | None = None,
        video_id: str | None = None,
    ) -> list[Dict[str, Any]]:
        clauses = ["project_id = ?"]
        params: list[Any] = [project_id]
        if job_type is not None:
            clauses.append("type = ?")
            params.append(job_type)
        if video_id is not None:
            clauses.append("video_id = ?")
            params.append(video_id)
        if states is not None:
            state_values = list(states)
            if not state_values:
                return []
            placeholders = ", ".join("?" for _ in state_values)
            clauses.append(f"state IN ({placeholders})")
            params.extend(state_values)
        query = (
            "SELECT * FROM jobs WHERE "
            + " AND ".join(clauses)
            + " ORDER BY created_at ASC"
        )
        with self.connect() as connection:
            return [dict(row) for row in connection.execute(query, tuple(params)).fetchall()]

    def update_job(
        self,
        job_id: str,
        state: str | None = None,
        stage: str | None = None,
        progress: float | None = None,
        checkpoint: Dict[str, Any] | None = None,
        error_code: str | None = None,
        error_message: str | None = None,
    ) -> Dict[str, Any]:
        fields = ["updated_at = ?"]
        values: list[Any] = [now_iso()]
        if state is not None:
            fields.append("state = ?")
            values.append(state)
            if state == "running":
                fields.append("started_at = COALESCE(started_at, ?)")
                values.append(now_iso())
            elif state in {"completed", "failed", "cancelled"}:
                fields.append("finished_at = COALESCE(finished_at, ?)")
                values.append(now_iso())
        if stage is not None:
            fields.append("stage = ?")
            values.append(stage)
        if progress is not None:
            fields.append("progress = ?")
            values.append(max(0.0, min(1.0, float(progress))))
        if checkpoint is not None:
            fields.append("checkpoint_json = ?")
            values.append(json.dumps(checkpoint, ensure_ascii=False))
        if error_code is not None:
            fields.append("error_code = ?")
            values.append(error_code)
        if error_message is not None:
            fields.append("error_message = ?")
            values.append(error_message)
        values.append(job_id)
        with self.connect() as connection:
            cursor = connection.execute(
                f"UPDATE jobs SET {', '.join(fields)} WHERE id = ?",
                values,
            )
            if cursor.rowcount != 1:
                raise LookupError("JOB_NOT_FOUND")
        job = self.get_job(job_id)
        if not job:
            raise LookupError("JOB_NOT_FOUND")
        return job

    def set_telemetry_consent(self, status: str) -> None:
        if status not in {"unknown", "granted", "denied"}:
            raise ValueError("INVALID_CONSENT_STATUS")
        timestamp = now_iso()
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO telemetry_consent (id, status, asked_at, changed_at) VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET status = excluded.status, changed_at = excluded.changed_at
                """,
                (status, timestamp, timestamp),
            )

    def statistics(self) -> Dict[str, Any]:
        with self.connect() as connection:
            project = connection.execute("SELECT * FROM projects LIMIT 1").fetchone()
            video = connection.execute("SELECT * FROM videos ORDER BY created_at DESC LIMIT 1").fetchone()
            review_rows = connection.execute(
                """
                SELECT COALESCE(r.status, 'pending') AS status,
                       r.reason, r.review_duration_ms, c.evidence_json
                FROM candidates c
                LEFT JOIN candidate_reviews r ON r.candidate_id = c.id
                """
            ).fetchall()
            candidates = len(review_rows)
            goals = sum(row["status"] == "goal" for row in review_rows)
            excluded = sum(row["status"] == "excluded" for row in review_rows)
            included = candidates - excluded
            pending = sum(row["status"] == "pending" for row in review_rows)
            reviewed = candidates - pending
            durations = []
            for row in review_rows:
                try:
                    duration = int(row["review_duration_ms"])
                except (TypeError, ValueError):
                    continue
                if duration >= 0:
                    durations.append(duration)
            reason_distribution: Dict[str, int] = {}
            for row in review_rows:
                reason = row["reason"]
                if reason:
                    reason_distribution[reason] = reason_distribution.get(reason, 0) + 1
            conflict_count = sum(has_evidence_conflict(row["evidence_json"]) for row in review_rows)
            exports = connection.execute(
                """
                SELECT COUNT(*) AS count,
                       COALESCE(SUM(duration_ms), 0) AS duration_ms,
                       COALESCE(SUM(file_size_bytes), 0) AS file_size_bytes
                FROM exports
                """
            ).fetchone()
            return {
                "project": dict(project) if project else None,
                "video": dict(video) if video else None,
                "candidate_count": candidates,
                "reviewed_count": reviewed,
                "included_count": included,
                "goal_count": goals,
                "excluded_count": excluded,
                "pending_count": pending,
                "confirmation_rate": goals / reviewed if reviewed else 0.0,
                "avg_review_duration_ms": round(sum(durations) / len(durations)) if durations else 0,
                "reason_distribution": reason_distribution,
                "conflict_count": conflict_count,
                "export_count": exports["count"],
                "export_duration_ms": exports["duration_ms"],
                "export_file_size_bytes": exports["file_size_bytes"],
            }

    def create_export(self, values: Dict[str, Any]) -> Dict[str, Any]:
        export_id = values.get("id") or new_id("export")
        timestamp = now_iso()
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO exports (
                    id, project_id, video_id, output_path, mode, candidate_count,
                    duration_ms, file_size_bytes, width, height, video_codec,
                    audio_codec, processing_ms, export_ms, algorithm_version,
                    metadata_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    export_id,
                    values["project_id"],
                    values.get("video_id"),
                    values["output_path"],
                    values["mode"],
                    int(values.get("candidate_count", 0)),
                    values.get("duration_ms"),
                    values.get("file_size_bytes"),
                    values.get("width"),
                    values.get("height"),
                    values.get("video_codec"),
                    values.get("audio_codec"),
                    values.get("processing_ms"),
                    values.get("export_ms"),
                    values.get("algorithm_version", "python-v1"),
                    json.dumps(values.get("metadata", {}), ensure_ascii=False),
                    timestamp,
                ),
            )
        return {"id": export_id, **values, "created_at": timestamp}

    def list_exports(self, project_id: str, limit: int = 20) -> list[Dict[str, Any]]:
        if limit <= 0 or limit > 100:
            raise ValueError("INVALID_EXPORT_LIMIT")
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT * FROM exports
                WHERE project_id = ?
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (project_id, limit),
            ).fetchall()
        exports = []
        for row in rows:
            item = dict(row)
            try:
                item["metadata"] = json.loads(item.pop("metadata_json") or "{}")
            except (TypeError, json.JSONDecodeError):
                item["metadata"] = {}
            exports.append(item)
        return exports

    def cleanup_artifacts(self, include_exports: bool = False) -> Dict[str, Any]:
        names = ["proxies", "detections", "review_clips"]
        if include_exports:
            names.append("exports")
        removed = []
        for name in names:
            path = self.root / "artifacts" / name
            if path.exists():
                for child in path.iterdir():
                    if child.is_symlink() or not child.is_dir():
                        child.unlink()
                    else:
                        shutil.rmtree(child)
                removed.append(str(path))
        return {"removed": removed}
