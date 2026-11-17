from __future__ import annotations

import hashlib
import json
import math
import os
import shutil
import sqlite3
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable
from uuid import uuid4

from .request_control import fingerprint
from .tiers import RULE_VERSION, calibrate, calibration_from_rows, classify, evidence_dict

# Same value as basketball_highlight.rim_check.AUTO_REVIEW_REASON.
AUTO_REVIEW_REASON = "auto_rim_check"


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
    return False


class _ClosingConnection(sqlite3.Connection):
    """with 块退出时同时关闭连接,而不是仅提交事务。

    默认 sqlite3 连接离开 with 后保持打开;Windows 上残留句柄会一直
    锁住 project.db,导致 delete_project 的 rmtree 报 WinError 32。
    """

    def __exit__(self, exc_type, exc_value, tb):
        try:
            super().__exit__(exc_type, exc_value, tb)
        finally:
            self.close()


class ProjectStore:
    def __init__(self, root_path: str | Path):
        self.root = Path(root_path).expanduser().resolve()
        self.db_path = self.root / "project.db"

    def initialize(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        for name in ("artifacts/proxies", "artifacts/detections", "artifacts/review_clips", "artifacts/exports", "artifacts/previews", "logs", "telemetry_outbox"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        schema_path = Path(__file__).resolve().parents[3] / "docs/architecture/SQLITE_SCHEMA_V1.sql"
        with sqlite3.connect(
            self.db_path, timeout=30.0, factory=_ClosingConnection
        ) as connection:
            connection.execute("PRAGMA foreign_keys = ON")
            connection.execute("PRAGMA busy_timeout = 30000")
            self._backup_before_tiers_migration(connection)
            connection.executescript(schema_path.read_text(encoding="utf-8"))
            self._ensure_schema_compatibility(connection)

    @staticmethod
    def _ensure_schema_compatibility(connection: sqlite3.Connection) -> None:
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS players (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(project_id, name)
            );
            CREATE INDEX IF NOT EXISTS idx_players_project_name
                ON players(project_id, name);
            """
        )
        video_columns = {
            row[1] for row in connection.execute("PRAGMA table_info(videos)").fetchall()
        }
        for name, definition in (
            ("source_fingerprint", "TEXT"),
            ("analysis_start_ms", "INTEGER NOT NULL DEFAULT 0"),
            ("analysis_end_ms", "INTEGER"),
            ("sort_index", "INTEGER NOT NULL DEFAULT 0"),
            ("recorded_at", "TEXT"),
            ("rotation", "INTEGER NOT NULL DEFAULT 0"),
        ):
            if name not in video_columns:
                connection.execute(f"ALTER TABLE videos ADD COLUMN {name} {definition}")
        project_columns = {
            row[1] for row in connection.execute("PRAGMA table_info(projects)").fetchall()
        }
        if "workflow_draft_json" not in project_columns:
            connection.execute("ALTER TABLE projects ADD COLUMN workflow_draft_json TEXT")
        columns = {
            row[1]
            for row in connection.execute("PRAGMA table_info(candidate_reviews)").fetchall()
        }
        for name, definition in (
            ("reason", "TEXT"),
            ("player_id", "TEXT REFERENCES players(id) ON DELETE SET NULL"),
            ("review_started_at", "TEXT"),
            ("review_duration_ms", "INTEGER"),
        ):
            if name not in columns:
                connection.execute(f"ALTER TABLE candidate_reviews ADD COLUMN {name} {definition}")

        if "tier_rule_version" not in project_columns:
            connection.execute("BEGIN IMMEDIATE")
            try:
                # Another opener may have migrated while we waited for the lock.
                if "tier_rule_version" not in {r[1] for r in connection.execute("PRAGMA table_info(projects)")}:
                    connection.execute("ALTER TABLE projects ADD COLUMN tier_rule_version TEXT NOT NULL DEFAULT 'r2-v1'")
                connection.commit()
            except Exception:
                connection.rollback()
                raise
        connection.executescript("""
            CREATE TABLE IF NOT EXISTS candidate_tags (
                candidate_id TEXT NOT NULL REFERENCES candidates(id) ON DELETE CASCADE,
                player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                PRIMARY KEY(candidate_id, player_id)
            );
            CREATE INDEX IF NOT EXISTS idx_candidate_tags_player ON candidate_tags(player_id);
            CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY);
        """)
        if not connection.execute("SELECT 1 FROM schema_migrations WHERE name='candidate_tags_v1'").fetchone():
            connection.execute("BEGIN IMMEDIATE")
            try:
                if not connection.execute("SELECT 1 FROM schema_migrations WHERE name='candidate_tags_v1'").fetchone():
                    connection.execute("""INSERT OR IGNORE INTO candidate_tags(candidate_id,player_id,position)
                        SELECT r.candidate_id,r.player_id,0 FROM candidate_reviews r
                        JOIN players p ON p.id=r.player_id JOIN candidates c ON c.id=r.candidate_id
                        JOIN videos v ON v.id=c.video_id AND v.project_id=p.project_id""")
                    connection.execute("INSERT INTO schema_migrations(name) VALUES ('candidate_tags_v1')")
                connection.commit()
            except Exception:
                connection.rollback()
                raise

    def set_tier_rule_version(self, version):
        if version != RULE_VERSION:
            raise ValueError("INVALID_TIER_RULE_VERSION")
        with self.connect() as connection:
            connection.execute("UPDATE projects SET tier_rule_version=?", (version,))
        return version

    def _backup_before_tiers_migration(self, connection: sqlite3.Connection) -> None:
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "candidates" not in tables:
            return  # New, empty databases have no user data to migrate.
        if "schema_migrations" in tables and connection.execute(
            "SELECT 1 FROM schema_migrations WHERE name='candidate_tags_v1'"
        ).fetchone():
            return
        backup = self.root / "project.db.pre-tiers-v1.bak"
        if backup.is_symlink():
            raise OSError("迁移备份不能是符号链接")
        if not backup.exists():
            handle, name = tempfile.mkstemp(prefix=".pre-tiers-", suffix=".tmp", dir=self.root)
            os.close(handle)
            temporary = Path(name)
            try:
                with sqlite3.connect(temporary, factory=_ClosingConnection) as target:
                    # SQLite backup includes committed WAL data, unlike copying project.db alone.
                    connection.backup(target)
                    if target.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                        raise OSError("迁移备份完整性检查失败")
                try:
                    # Atomic publish without replacing another opener's original backup.
                    os.link(temporary, backup)
                except FileExistsError:
                    pass
            finally:
                temporary.unlink(missing_ok=True)
        with sqlite3.connect(backup.as_uri() + "?mode=ro&immutable=1", uri=True,
                             factory=_ClosingConnection) as saved:
            if saved.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise OSError("迁移备份完整性检查失败")
            expected = sorted(row[0] for row in connection.execute("SELECT id FROM projects"))
            actual = sorted(row[0] for row in saved.execute("SELECT id FROM projects"))
            if expected != actual:
                raise OSError("迁移备份不属于当前项目")

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(
            self.db_path.as_uri() + '?mode=rw', uri=True, timeout=30.0, factory=_ClosingConnection
        )
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 30000")
        try:
            self._backup_before_tiers_migration(connection)
            self._ensure_schema_compatibility(connection)
        except Exception:
            connection.close()
            raise
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

    def analysis_mode(self) -> str:
        project = self.project()
        if not project:
            raise LookupError("PROJECT_NOT_FOUND")
        with self.connect() as connection:
            row = connection.execute(
                "SELECT value_json FROM settings WHERE key = ?",
                (f"project:{project['id']}:analysis_mode",),
            ).fetchone()
        if not row:
            return "standard"
        try:
            value = json.loads(row["value_json"])
        except (TypeError, json.JSONDecodeError):
            return "standard"
        return value if value in {"fast", "standard"} else "standard"

    def set_analysis_mode(self, mode: str) -> str:
        if mode not in {"fast", "standard"}:
            raise ValueError("ANALYSIS_MODE_INVALID")
        project = self.project()
        if not project:
            raise LookupError("PROJECT_NOT_FOUND")
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json,
                                                updated_at = excluded.updated_at
                """,
                (f"project:{project['id']}:analysis_mode", json.dumps(mode), now_iso()),
            )
        return mode

    def workflow_draft(self) -> Dict[str, Any] | None:
        project = self.project()
        if not project:
            raise LookupError("PROJECT_NOT_FOUND")
        raw = project.get("workflow_draft_json")
        if not raw:
            return None
        try:
            draft = json.loads(raw)
        except (TypeError, json.JSONDecodeError) as exc:
            raise ValueError("WORKFLOW_DRAFT_INVALID") from exc
        return draft if isinstance(draft, dict) else None

    def save_workflow_draft(self, draft: Dict[str, Any]) -> Dict[str, Any]:
        project = self.project()
        if not project:
            raise LookupError("PROJECT_NOT_FOUND")
        encoded = json.dumps(draft, ensure_ascii=False)
        with self.connect() as connection:
            connection.execute(
                "UPDATE projects SET workflow_draft_json = ?, updated_at = ? WHERE id = ?",
                (encoded, now_iso(), project["id"]),
            )
        return draft

    def clear_workflow_draft(self) -> None:
        project = self.project()
        if not project:
            raise LookupError("PROJECT_NOT_FOUND")
        with self.connect() as connection:
            connection.execute(
                "UPDATE projects SET workflow_draft_json = NULL, updated_at = ? WHERE id = ?",
                (now_iso(), project["id"]),
            )

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

    def list_videos(self) -> list[Dict[str, Any]]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM videos ORDER BY sort_index, created_at"
            ).fetchall()
        return [dict(row) for row in rows]

    def reorder_videos(self, video_ids: list[str]) -> list[Dict[str, Any]]:
        if sorted(video_ids) != sorted(video["id"] for video in self.list_videos()):
            raise ValueError("VIDEO_ORDER_INVALID")
        timestamp = now_iso()
        with self.connect() as connection:
            for index, video_id in enumerate(video_ids):
                connection.execute(
                    "UPDATE videos SET sort_index = ?, updated_at = ? WHERE id = ?",
                    (index, timestamp, video_id),
                )
        return self.list_videos()

    def analysis_queue(self) -> Dict[str, Any]:
        project = self.project()
        if not project:
            raise LookupError("PROJECT_NOT_FOUND")
        with self.connect() as connection:
            row = connection.execute(
                "SELECT value_json FROM settings WHERE key = ?",
                (f"project:{project['id']}:analysis_queue",),
            ).fetchone()
        empty = {"video_ids": [], "before_seconds": 3, "after_seconds": 1}
        if not row:
            return empty
        try:
            value = json.loads(row["value_json"])
        except (TypeError, json.JSONDecodeError):
            return empty
        if not isinstance(value, dict) or not isinstance(value.get("video_ids"), list):
            return empty
        return {**empty, **value}

    def set_analysis_queue(
        self,
        video_ids: list[str],
        before_seconds: float = 3,
        after_seconds: float = 1,
    ) -> Dict[str, Any]:
        project = self.project()
        if not project:
            raise LookupError("PROJECT_NOT_FOUND")
        known = {video["id"] for video in self.list_videos()}
        if any(video_id not in known for video_id in video_ids) or len(set(video_ids)) != len(video_ids):
            raise ValueError("ANALYSIS_QUEUE_INVALID")
        queue = {
            "video_ids": video_ids,
            "before_seconds": before_seconds,
            "after_seconds": after_seconds,
        }
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json,
                                                updated_at = excluded.updated_at
                """,
                (f"project:{project['id']}:analysis_queue", json.dumps(queue), now_iso()),
            )
        return queue

    def video_source_paths(self) -> list[str]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT source_path FROM videos WHERE source_path IS NOT NULL"
            ).fetchall()
        return [str(row["source_path"]) for row in rows]

    def recent_context(self) -> tuple[Dict[str, Any], list[Dict[str, Any]]]:
        """Read committed list metadata without writing any source DB/sidecar.

        SQLite may update SHM even in mode=ro. Replay WAL only on a disposable
        copy; if copying races a writer or fails, counts are explicitly unknown.
        """
        try:
            wal = Path(str(self.db_path) + "-wal")
            if not wal.exists() or wal.stat().st_size == 0:
                return self._recent_context(self.db_path, immutable=True)
            files = [self.db_path, wal, Path(str(self.db_path) + "-shm")]

            def signatures():
                result = {}
                for path in files:
                    try:
                        stat = path.stat()
                    except FileNotFoundError:
                        result[path.name] = None
                    else:
                        result[path.name] = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
                return result

            before = signatures()
            with tempfile.TemporaryDirectory(prefix="bhe-recent-") as directory:
                snapshot = Path(directory) / self.db_path.name
                for path in files:
                    if before[path.name] is not None:
                        shutil.copyfile(path, Path(directory) / path.name)
                if signatures() != before:
                    raise OSError("Recent-project snapshot changed while copying")
                return self._recent_context(snapshot, immutable=False)
        except (OSError, sqlite3.Error, ValueError):
            # Main-file metadata is still useful, but none of its counts can be
            # trusted after failing to read the committed WAL snapshot.
            try:
                context, _ = self._recent_context(self.db_path, immutable=True)
            except (OSError, sqlite3.Error, ValueError):
                context = {
                    "database_path": str(self.db_path), "project_root": str(self.root),
                    "project": {"name": self.root.name}, "videos": [], "video": None,
                    "statistics": {key: None for key in (
                        "candidate_count", "included_count", "goal_count", "excluded_count",
                        "pending_count", "reviewed_count", "export_count")},
                }
            context["statistics"] = {key: None for key in context["statistics"]}
            return context, []

    def _recent_context(self, db_path: Path, *, immutable: bool) -> tuple[Dict[str, Any], list[Dict[str, Any]]]:
        uri = db_path.as_uri() + ("?mode=ro&immutable=1" if immutable else "?mode=ro")
        with sqlite3.connect(uri, uri=True, factory=_ClosingConnection) as connection:
            connection.row_factory = sqlite3.Row
            project_row = connection.execute("SELECT * FROM projects LIMIT 1").fetchone()
            if project_row is None:
                raise ValueError("PROJECT_NOT_FOUND")
            project = dict(project_row)
            tables = {row[0] for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")}
            videos = [dict(row) for row in connection.execute("SELECT * FROM videos")] if "videos" in tables else []
            videos.sort(key=lambda row: (row.get("sort_index", 0), row.get("created_at", ""), row["id"]))
            for video in videos:
                video.setdefault("rotation", 0)
                video.setdefault("sort_index", 0)
                exists = Path(video["source_path"]).is_file()
                video.update(source_exists=exists, source_status="linked" if exists else "missing")
            # Only the stable fields needed for counts and existing-frame lookup.
            candidates = [dict(row) for row in connection.execute(
                "SELECT id, video_id, event_time_ms FROM candidates")
            ] if "candidates" in tables else []
            statuses = {row["candidate_id"]: row["status"] for row in connection.execute(
                "SELECT candidate_id, status FROM candidate_reviews")
            } if "candidate_reviews" in tables else {}
            for row in candidates:
                row["selection_status"] = statuses.get(row["id"], "pending")
            count = len(candidates)
            excluded = sum(row["selection_status"] == "excluded" for row in candidates)
            goals = sum(row["selection_status"] == "goal" for row in candidates)
            pending = sum(row["selection_status"] == "pending" for row in candidates)
            exports = connection.execute("SELECT COUNT(*) FROM exports").fetchone()[0] if "exports" in tables else 0
        project.setdefault("tier_rule_version", RULE_VERSION)
        video = videos[0] if videos else None
        return {
            "database_path": str(self.db_path), "project_root": str(self.root),
            "project": project, "analysis_mode": "standard", "workflow_draft": None,
            "video": video, "videos": videos, "roi": None,
            "statistics": {"candidate_count": count, "included_count": count - excluded,
                           "goal_count": goals, "excluded_count": excluded,
                           "pending_count": pending, "reviewed_count": count - pending,
                           "export_count": exports},
        }, candidates

    def context(self) -> Dict[str, Any]:
        project = self.project()
        if not project:
            raise ValueError("PROJECT_NOT_FOUND")
        videos = self.video_summaries(project["id"])
        video = videos[0] if videos else None
        return {
            "database_path": str(self.db_path),
            "project_root": str(self.root),
            "project": project,
            "analysis_mode": self.analysis_mode(),
            "workflow_draft": self.workflow_draft(),
            "video": {key: value for key, value in video.items() if key not in {"roi", "analysis_job", "candidate_count"}} if video else None,
            "roi": video["roi"] if video else None,
            "videos": videos,
            "analysis_queue": self.analysis_queue(),
            "statistics": self.statistics(),
        }

    def video_summaries(self, project_id: str) -> list[Dict[str, Any]]:
        with self.connect() as connection:
            counts = {
                row["video_id"]: row["count"]
                for row in connection.execute(
                    "SELECT video_id, COUNT(*) AS count FROM candidates GROUP BY video_id"
                ).fetchall()
            }
        summaries = []
        for video in self.list_videos():
            source = Path(video["source_path"])
            jobs = self.list_jobs(project_id, "analysis", video_id=video["id"], descending=True)
            job = jobs[0] if jobs else None
            summaries.append({
                **video,
                "source_exists": source.is_file(),
                "source_status": "linked" if source.is_file() else "missing",
                "roi": self.active_roi(video["id"]),
                "analysis_job": {
                    key: job.get(key)
                    for key in ("id", "state", "stage", "progress", "error_code", "error_message", "finished_at")
                } if job else None,
                "candidate_count": counts.get(video["id"], 0),
            })
        return summaries

    @staticmethod
    def _source_fingerprint(path: str | Path) -> str | None:
        source = Path(path)
        try:
            return fingerprint(source)
        except OSError:
            return None

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
            metadata.get("source_fingerprint") or self._source_fingerprint(metadata["source_path"]),
            metadata.get("duration_ms"),
            metadata.get("width"),
            metadata.get("height"),
            int(metadata.get("rotation") or 0),
            metadata.get("fps"),
            metadata.get("video_codec"),
            metadata.get("audio_codec"),
            0,
            metadata.get("duration_ms"),
            metadata.get("recorded_at"),
            timestamp,
            timestamp,
        )
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO videos (
                    id, project_id, source_path, source_size_bytes, source_mtime_ns,
                    source_fingerprint, duration_ms, width, height, rotation, fps,
                    video_codec, audio_codec,
                    analysis_start_ms, analysis_end_ms, recorded_at, sort_index,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                          (SELECT COALESCE(MAX(sort_index), -1) + 1 FROM videos), ?, ?)
                """,
                values,
            )
        return {**metadata, **(self.video(video_id) or {})}

    def video(self, video_id: str) -> Dict[str, Any] | None:
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM videos WHERE id = ?", (video_id,)).fetchone()
        return dict(row) if row else None

    def set_video_rotation(self, video_id: str, rotation: int) -> Dict[str, Any] | None:
        """Record the source rotation without invalidating analysis.

        Only the display orientation changes, so the stored ROI and candidates
        stay valid; relink_video would drop them.
        """
        with self.connect() as connection:
            cursor = connection.execute(
                "UPDATE videos SET rotation = ?, updated_at = ? WHERE id = ?",
                (int(rotation), now_iso(), video_id),
            )
            if cursor.rowcount != 1:
                raise LookupError("VIDEO_NOT_FOUND")
        return self.video(video_id)

    def set_analysis_range(
        self,
        video_id: str,
        start_ms: int,
        end_ms: int,
    ) -> Dict[str, Any]:
        video = self.video(video_id)
        if not video:
            raise LookupError("VIDEO_NOT_FOUND")
        duration_ms = int(video.get("duration_ms") or 0)
        if start_ms < 0 or end_ms <= start_ms or (duration_ms > 0 and end_ms > duration_ms):
            raise ValueError("ANALYSIS_RANGE_INVALID")
        with self.connect() as connection:
            connection.execute(
                "UPDATE videos SET analysis_start_ms = ?, analysis_end_ms = ?, updated_at = ? WHERE id = ?",
                (start_ms, end_ms, now_iso(), video_id),
            )
        updated = self.video(video_id)
        if not updated:
            raise LookupError("VIDEO_NOT_FOUND")
        return updated

    def relink_video(self, video_id: str, metadata: Dict[str, Any]) -> Dict[str, Any]:
        """Replace the source reference and invalidate analysis for changed media."""
        source_path = metadata.get("source_path")
        if not isinstance(source_path, str) or not source_path.strip():
            raise ValueError("VIDEO_PATH_INVALID")
        previous = self.video(video_id)
        if not previous:
            raise LookupError("VIDEO_NOT_FOUND")
        previous_fingerprint = previous.get("source_fingerprint")
        next_fingerprint = metadata.get("source_fingerprint") or self._source_fingerprint(source_path)
        fingerprint_fields = (
            "source_size_bytes", "duration_ms", "width",
            "height", "fps", "video_codec", "audio_codec",
        )
        analysis_invalidated = (
            previous_fingerprint is None
            or next_fingerprint is None
            or previous_fingerprint != next_fingerprint
            or any(previous.get(field) != metadata.get(field) for field in fingerprint_fields)
        )
        timestamp = now_iso()
        with self.connect() as connection:
            cursor = connection.execute(
                """
                UPDATE videos SET
                    source_path = ?, source_size_bytes = ?, source_mtime_ns = ?,
                    source_fingerprint = ?, duration_ms = ?, width = ?, height = ?,
                    rotation = ?, fps = ?,
                    video_codec = ?, audio_codec = ?,
                    status = 'linked', updated_at = ?
                WHERE id = ?
                """,
                (
                    source_path,
                    metadata["source_size_bytes"],
                    metadata["source_mtime_ns"],
                    next_fingerprint,
                    metadata.get("duration_ms"),
                    metadata.get("width"),
                    metadata.get("height"),
                    int(metadata.get("rotation") or 0),
                    metadata.get("fps"),
                    metadata.get("video_codec"),
                    metadata.get("audio_codec"),
                    timestamp,
                    video_id,
                ),
            )
            if cursor.rowcount != 1:
                raise LookupError("VIDEO_NOT_FOUND")
            if analysis_invalidated:
                connection.execute("DELETE FROM candidates WHERE video_id = ?", (video_id,))
                connection.execute("DELETE FROM rois WHERE video_id = ?", (video_id,))
        if analysis_invalidated:
            preview_dir = self.root / "artifacts" / "previews"
            if preview_dir.is_dir():
                for preview in preview_dir.glob(f"{video_id}_*.jpg"):
                    preview.unlink(missing_ok=True)
        video = self.video(video_id)
        if not video:
            raise LookupError("VIDEO_NOT_FOUND")
        video["source_exists"] = True
        video["source_status"] = "linked"
        video["analysis_invalidated"] = analysis_invalidated
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
                   COALESCE(r.status, 'pending') AS selection_status,
                   r.reason AS review_reason, r.note, r.reviewed_at,
                   r.review_started_at, r.review_duration_ms,
                   r.player_id, p.name AS player_name
            FROM candidates c
            LEFT JOIN candidate_reviews r ON r.candidate_id = c.id
            LEFT JOIN players p ON p.id = r.player_id
            JOIN videos v ON v.id = c.video_id
        """
        params: Iterable[Any] = ()
        if video_id:
            query += " WHERE c.video_id = ?"
            params = (video_id,)
        query += " ORDER BY v.sort_index, v.created_at, c.event_time_ms"
        with self.connect() as connection:
            rows = [dict(row) for row in connection.execute(query, tuple(params)).fetchall()]
            all_tags = {}
            for tag in connection.execute("""SELECT t.candidate_id,p.id,p.name FROM candidate_tags t
                    JOIN players p ON p.id=t.player_id ORDER BY t.candidate_id,t.position,p.id"""):
                all_tags.setdefault(tag["candidate_id"], []).append({"id":tag["id"], "name":tag["name"]})
            project = connection.execute("SELECT tier_rule_version FROM projects LIMIT 1").fetchone()
            # Legacy projects lack analysis-time calibration. Use the entire
            # current project (also when listing only one video), in memory only.
            baseline = calibration_from_rows([dict(item) for item in connection.execute(
                "SELECT evidence_json FROM candidates")])
        for row in rows:
            tags = all_tags.get(row["id"], [])
            row.update(tags=tags, players=tags, player_id=tags[0]["id"] if tags else None,
                       player_name=tags[0]["name"] if tags else None)
            evidence = evidence_dict(row.get("evidence_json"))
            evidence.update(review_status=row["review_status"], review_reason=row["review_reason"])
            saved = evidence_dict(evidence_dict(evidence_dict(evidence.get("rim_check")).get("experiment")).get("net_calibration"))
            if not evidence_dict(evidence.get("tier_calibration")) and saved.get("scope") != "analysis_run_baseline_made":
                evidence["tier_calibration"] = baseline
            tier = classify(evidence, evidence.get("analysis_mode", "standard"), project["tier_rule_version"] if project else RULE_VERSION)
            row.update(tier=tier["tier"], tier_reason=tier["reason"], tier_source=tier["source"],
                       selection_status={"must":"included", "suspect":"pending", "excluded":"excluded"}[tier["tier"]])
        return rows

    def create_manual_candidate(
        self,
        video_id: str,
        start_ms: int,
        end_ms: int,
        event_time_ms: int | None = None,
    ) -> Dict[str, Any]:
        if start_ms < 0 or end_ms <= start_ms:
            raise ValueError("INVALID_CLIP_RANGE")
        video = self.video(video_id)
        if not video:
            raise LookupError("VIDEO_NOT_FOUND")
        duration_ms = video.get("duration_ms")
        if duration_ms is not None and end_ms > int(duration_ms):
            raise ValueError("INVALID_CLIP_RANGE")
        timestamp = now_iso()
        event_time_ms = (
            (start_ms + end_ms) // 2
            if event_time_ms is None
            else int(event_time_ms)
        )
        if event_time_ms < start_ms or event_time_ms > end_ms:
            raise ValueError("INVALID_EVENT_TIME")
        roi = self.active_roi(video_id)
        candidate_id = new_id("candidate")
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO candidates (
                    id, video_id, roi_id, group_id, event_time_ms,
                    default_start_ms, default_end_ms, review_start_ms, review_end_ms,
                    detector_version, score, confidence, evidence_json, created_at, updated_at
                ) VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
                """,
                (
                    candidate_id,
                    video_id,
                    roi["id"] if roi else None,
                    event_time_ms,
                    start_ms,
                    end_ms,
                    start_ms,
                    end_ms,
                    "manual-v1",
                    "manual",
                    json.dumps(
                        {
                            "source": "manual",
                            "analysis_source": "manual",
                        },
                        ensure_ascii=False,
                    ),
                    timestamp,
                    timestamp,
                ),
            )
            connection.execute(
                """
                INSERT INTO candidate_reviews (
                    candidate_id, status, updated_at
                ) VALUES (?, 'pending', ?)
                """,
                (candidate_id, timestamp),
            )
        candidate = next(
            candidate
            for candidate in self.list_candidates(video_id)
            if candidate["id"] == candidate_id
        )
        return candidate

    def replace_candidates(
        self,
        video_id: str,
        rows: list[Dict[str, Any]],
        before_commit=None,
    ) -> None:
        """替换候选。`before_commit` 在同一个事务里、提交之前调用：它抛异常整个替换回滚。"""
        timestamp = now_iso()
        rows = calibrate(rows, self.analysis_mode(), new_id("analysis"))
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            video_row = connection.execute(
                "SELECT duration_ms FROM videos WHERE id = ?",
                (video_id,),
            ).fetchone()
            if not video_row:
                raise LookupError("VIDEO_NOT_FOUND")
            duration_ms = video_row["duration_ms"]
            duration_ms = int(duration_ms) if duration_ms is not None else None
            manual_rows = [
                dict(row)
                for row in connection.execute(
                    """
                    SELECT id, roi_id, group_id, event_time_ms,
                           default_start_ms, default_end_ms,
                           review_start_ms, review_end_ms,
                           detector_version, score, confidence,
                           evidence_json, created_at, updated_at
                    FROM candidates
                    WHERE video_id = ? AND detector_version = 'manual-v1'
                    """,
                    (video_id,),
                ).fetchall()
            ]
            existing_ids = {str(row.get("id")) for row in rows}
            rows = [*rows, *[row for row in manual_rows if str(row["id"]) not in existing_ids]]
            existing_candidates = {
                row["id"]: dict(row)
                for row in connection.execute(
                    "SELECT id, roi_id, event_time_ms, default_start_ms, default_end_ms, review_start_ms, review_end_ms "
                    "FROM candidates WHERE video_id = ?",
                    (video_id,),
                ).fetchall()
            }
            existing_reviews = {
                row["candidate_id"]: dict(row)
                for row in connection.execute(
                    "SELECT candidate_id, status, reason, note, reviewed_at, review_started_at, review_duration_ms, player_id "
                    "FROM candidate_reviews "
                    "WHERE candidate_id IN (SELECT id FROM candidates WHERE video_id = ?)",
                    (video_id,),
                ).fetchall()
            }
            old_tags = {}
            for tag in connection.execute("SELECT * FROM candidate_tags ORDER BY position"):
                old_tags.setdefault(tag["candidate_id"], []).append(tag["player_id"])
            matches: dict[str, dict[str, Any]] = {}
            reserved_exact_ids = {str(row["id"]) for row in rows} & existing_candidates.keys()
            for row in rows:
                candidate_id = str(row["id"])
                review = existing_reviews.get(candidate_id)
                old_candidate = existing_candidates.get(candidate_id)
                if review is None:
                    candidates = [
                        (abs(int(old["event_time_ms"]) - int(row["event_time_ms"])), old_id, old)
                        for old_id, old in existing_candidates.items()
                        if old.get("roi_id") == row.get("roi_id")
                        and abs(int(old["event_time_ms"]) - int(row["event_time_ms"])) <= 2_000
                    ]
                    candidates.sort(key=lambda item: (item[0], item[1]))
                    if candidates and (
                        len(candidates) == 1
                        or candidates[0][0] < candidates[1][0]
                    ):
                        distance, old_id, old = candidates[0]
                        # Both nearest checks use the complete, unchanged sets.
                        # An unavailable nearest event cannot fall back to second best.
                        nearest_new = [str(item["id"]) for item in rows
                                       if item.get("roi_id") == old.get("roi_id")
                                       and abs(int(item["event_time_ms"]) - int(old["event_time_ms"])) <= distance]
                        if old_id not in reserved_exact_ids and nearest_new == [candidate_id]:
                            old_candidate = old
                            review = existing_reviews.get(old_id)
                if old_candidate is not None:
                    event_delta = int(row["event_time_ms"]) - int(old_candidate["event_time_ms"])
                    old_default_start = int(old_candidate["default_start_ms"])
                    old_default_end = int(old_candidate["default_end_ms"])
                    if (
                        int(old_candidate["review_start_ms"]) != old_default_start
                        or int(old_candidate["review_end_ms"]) != old_default_end
                    ):
                        shifted_start = int(old_candidate["review_start_ms"]) + event_delta
                        shifted_end = int(old_candidate["review_end_ms"]) + event_delta
                        if duration_ms is not None and duration_ms > 0:
                            shifted_start = max(0, min(shifted_start, duration_ms - 1))
                            shifted_end = max(shifted_start + 1, min(shifted_end, duration_ms))
                        else:
                            shifted_start = max(0, shifted_start)
                            shifted_end = max(shifted_start + 1, shifted_end)
                        row["review_start_ms"] = shifted_start
                        row["review_end_ms"] = shifted_end
                if review is not None:
                    matches[candidate_id] = {**review, "tags":old_tags.get(review["candidate_id"], [])}
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
                review = matches.get(row["id"])
                status = review["status"] if review else "pending"
                reason = review["reason"] if review else None
                # 自动复核只决定"没人审过"的候选:新候选,或上次也是自动
                # 排除且用户没改过的候选。人工审核结果一律保留。
                if review is None or (
                    review["status"] == "excluded" and review["reason"] == AUTO_REVIEW_REASON
                ):
                    status = row.get("auto_review_status") or "pending"
                    reason = row.get("auto_review_reason") if row.get("auto_review_status") else None
                connection.execute(
                    """
                    INSERT INTO candidate_reviews (
                        candidate_id, player_id, status, reason, note, reviewed_at,
                        review_started_at, review_duration_ms, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        row["id"],
                        review["tags"][0] if review and review.get("tags") else None,
                        status,
                        reason,
                        review["note"] if review else None,
                        review["reviewed_at"] if review else None,
                        review["review_started_at"] if review else None,
                        review["review_duration_ms"] if review else None,
                        timestamp,
                    ),
                )
                for position, player_id in enumerate(review.get("tags", []) if review else []):
                    connection.execute("INSERT INTO candidate_tags VALUES (?,?,?)", (row["id"],player_id,position))
            if before_commit is not None:
                before_commit()

    def list_players(self) -> list[Dict[str, Any]]:
        project = self.project()
        if not project:
            raise ValueError("PROJECT_NOT_INITIALIZED")
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM players WHERE project_id = ? ORDER BY created_at, rowid",
                (project["id"],),
            ).fetchall()
        return [dict(row) for row in rows]

    def create_player(self, name: str) -> Dict[str, Any]:
        project = self.project()
        if not project:
            raise ValueError("PROJECT_NOT_INITIALIZED")
        normalized = name.strip()
        if not normalized:
            raise ValueError("PLAYER_NAME_INVALID")
        timestamp = now_iso()
        player = {"id": new_id("player"), "project_id": project["id"], "name": normalized,
                  "created_at": timestamp, "updated_at": timestamp}
        try:
            with self.connect() as connection:
                connection.execute(
                    "INSERT INTO players (id, project_id, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                    (player["id"], player["project_id"], player["name"], timestamp, timestamp),
                )
        except sqlite3.IntegrityError as exc:
            raise ValueError("PLAYER_ALREADY_EXISTS") from exc
        return player

    def delete_player(self, player_id: str) -> None:
        project = self.project()
        if not project:
            raise ValueError("PROJECT_NOT_INITIALIZED")
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            player = connection.execute(
                "SELECT id FROM players WHERE id = ? AND project_id = ?",
                (player_id, project["id"]),
            ).fetchone()
            if not player:
                raise LookupError("PLAYER_NOT_FOUND")
            affected = [row[0] for row in connection.execute("SELECT candidate_id FROM candidate_tags WHERE player_id=?", (player_id,))]
            connection.execute("DELETE FROM players WHERE id = ?", (player_id,))
            for candidate_id in affected:
                connection.execute("""UPDATE candidate_reviews SET player_id=(SELECT player_id FROM candidate_tags
                    WHERE candidate_id=? ORDER BY position LIMIT 1) WHERE candidate_id=?""", (candidate_id,candidate_id))

    def set_candidate_player(self, candidate_id, player_id):
        self.set_candidates_players([candidate_id], [] if player_id is None else [player_id])

    def set_candidates_player(self, candidate_ids, player_id):
        return self.set_candidates_players(candidate_ids, [] if player_id is None else [player_id])

    def set_candidate_players(self, candidate_id, player_ids):
        return self.set_candidates_players([candidate_id], player_ids)

    def set_candidates_players(self, candidate_ids, player_ids, operation="set"):
        if not isinstance(candidate_ids, list) or not all(isinstance(x,str) and x for x in candidate_ids):
            raise ValueError("INVALID_CANDIDATE_IDS")
        if not isinstance(player_ids, list) or not all(isinstance(x,str) and x for x in player_ids):
            raise ValueError("INVALID_PLAYER_IDS")
        if operation not in {"set", "add", "remove"}:
            raise ValueError("INVALID_TAG_OPERATION")
        ids, players = list(dict.fromkeys(candidate_ids)), list(dict.fromkeys(player_ids))
        with self.connect() as connection:
            # Lock before read so two append/remove requests cannot overwrite each other.
            connection.execute("BEGIN IMMEDIATE")
            for candidate_id in ids:
                candidate = connection.execute("""SELECT v.project_id FROM candidates c
                    JOIN videos v ON v.id=c.video_id WHERE c.id=?""", (candidate_id,)).fetchone()
                if not candidate:
                    raise LookupError("CANDIDATE_NOT_FOUND")
                for player_id in players:
                    if not connection.execute("SELECT 1 FROM players WHERE id=? AND project_id=?",
                                              (player_id,candidate["project_id"])).fetchone():
                        raise LookupError("PLAYER_NOT_FOUND")
                old = [row[0] for row in connection.execute(
                    "SELECT player_id FROM candidate_tags WHERE candidate_id=? ORDER BY position", (candidate_id,))]
                selected = players if operation == "set" else (
                    list(dict.fromkeys(old+players)) if operation == "add" else [x for x in old if x not in players])
                connection.execute("DELETE FROM candidate_tags WHERE candidate_id=?", (candidate_id,))
                connection.executemany("INSERT INTO candidate_tags VALUES (?,?,?)",
                    [(candidate_id,player_id,position) for position,player_id in enumerate(selected)])
                connection.execute("""INSERT INTO candidate_reviews(candidate_id,player_id,status,updated_at)
                    VALUES (?,?,'pending',?) ON CONFLICT(candidate_id) DO UPDATE SET
                    player_id=excluded.player_id,updated_at=excluded.updated_at""",
                    (candidate_id,selected[0] if selected else None,now_iso()))
        return len(ids)

    def add_candidate_player(self, candidate_id, player_id):
        return self.set_candidates_players([candidate_id], [player_id], "add")

    def remove_candidate_player(self, candidate_id, player_id):
        return self.set_candidates_players([candidate_id], [player_id], "remove")

    def add_candidates_player(self, candidate_ids, player_id):
        return self.set_candidates_players(candidate_ids, [player_id], "add")

    def remove_candidates_player(self, candidate_ids, player_id):
        return self.set_candidates_players(candidate_ids, [player_id], "remove")

    def start_review(self, candidate_id: str, review_started_at: str | None = None) -> str:
        timestamp = normalize_review_started_at(review_started_at) if review_started_at is not None else now_iso()
        with self.connect() as connection:
            if not connection.execute("SELECT 1 FROM candidates WHERE id = ?", (candidate_id,)).fetchone():
                raise LookupError("CANDIDATE_NOT_FOUND")
            existing = connection.execute(
                "SELECT review_started_at FROM candidate_reviews WHERE candidate_id = ?",
                (candidate_id,),
            ).fetchone()
            if existing and existing["review_started_at"]:
                return str(existing["review_started_at"])
            cursor = connection.execute(
                """
                UPDATE candidate_reviews
                SET review_started_at = ?, review_duration_ms = NULL, updated_at = ?
                WHERE candidate_id = ? AND review_started_at IS NULL
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
            "made",
            "other",
            AUTO_REVIEW_REASON,
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

    def update_clip_ranges(
        self,
        candidate_ids: list[str],
        before_ms: int,
        after_ms: int,
        overwrite_manual: bool = False,
    ) -> Dict[str, int]:
        """Apply an event-centered range to candidates in one transaction."""
        if before_ms < 0 or after_ms < 0:
            raise ValueError("INVALID_CLIP_RANGE")
        ids = list(dict.fromkeys(str(item) for item in candidate_ids if str(item)))
        if not ids:
            return {"updated": 0, "skipped_manual": 0, "skipped_invalid": 0, "total": 0}
        placeholders = ",".join("?" for _ in ids)
        now = now_iso()
        updated = 0
        skipped_manual = 0
        # Clips whose event sits at the very end cannot take the new window;
        # they keep their range instead of failing the whole batch.
        skipped_invalid = 0
        with self.connect() as connection:
            rows = connection.execute(
                f"""
                SELECT c.id, c.event_time_ms, c.default_start_ms, c.default_end_ms,
                       c.review_start_ms, c.review_end_ms, v.duration_ms
                FROM candidates c
                JOIN videos v ON v.id = c.video_id
                WHERE c.id IN ({placeholders})
                """,
                ids,
            ).fetchall()
            if len(rows) != len(ids):
                raise LookupError("CANDIDATE_NOT_FOUND")
            for row in rows:
                manually_edited = (
                    int(row["review_start_ms"]) != int(row["default_start_ms"])
                    or int(row["review_end_ms"]) != int(row["default_end_ms"])
                )
                if manually_edited and not overwrite_manual:
                    skipped_manual += 1
                    continue
                start = max(0, int(row["event_time_ms"]) - before_ms)
                end = int(row["event_time_ms"]) + after_ms
                if row["duration_ms"] is not None:
                    end = min(end, int(row["duration_ms"]))
                if end <= start:
                    skipped_invalid += 1
                    continue
                connection.execute(
                    "UPDATE candidates SET review_start_ms = ?, review_end_ms = ?, updated_at = ? WHERE id = ?",
                    (start, end, now, row["id"]),
                )
                updated += 1
        return {
            "updated": updated,
            "skipped_manual": skipped_manual,
            "skipped_invalid": skipped_invalid,
            "total": len(rows),
        }

    def create_job(self, project_id: str, video_id: str | None, job_type: str, checkpoint: Dict[str, Any] | None = None, *, connection=None) -> Dict[str, Any]:
        if connection is None:
            with self.connect() as connection:
                return self.create_job(project_id, video_id, job_type, checkpoint, connection=connection)
        job_id = new_id("job")
        timestamp = now_iso()
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
        descending: bool = False,
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
            + f" ORDER BY created_at {'DESC' if descending else 'ASC'}, id {'DESC' if descending else 'ASC'}"
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
        allow_terminal_transition: bool = False,
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
            # 已进入取消收尾的任务保留 cancelling 显示，不被后续进度写入盖回普通阶段。
            if state is None or state == "running":
                fields.append(
                    "stage = CASE WHEN stage = 'cancelling' THEN stage ELSE ? END"
                )
            else:
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
            query = f"UPDATE jobs SET {', '.join(fields)} WHERE id = ?"
            if not allow_terminal_transition:
                query += " AND state NOT IN ('completed', 'failed', 'cancelled')"
            cursor = connection.execute(query, values)
            if cursor.rowcount != 1:
                current = connection.execute(
                    "SELECT state FROM jobs WHERE id = ?", (job_id,)
                ).fetchone()
                if current is None:
                    raise LookupError("JOB_NOT_FOUND")
                if current["state"] in {"completed", "failed", "cancelled"}:
                    job = self.get_job(job_id)
                    if job:
                        return job
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
            video = connection.execute("SELECT * FROM videos ORDER BY sort_index, created_at LIMIT 1").fetchone()
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

    def create_export(self, values: Dict[str, Any], *, connection=None) -> Dict[str, Any]:
        if connection is None:
            with self.connect() as connection:
                return self.create_export(values, connection=connection)
        export_id = values.get("id") or new_id("export")
        timestamp = now_iso()
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

    def complete_export_job(self, values: Dict[str, Any], job_id: str, checkpoint: Dict[str, Any]) -> Dict[str, Any]:
        """Publish history and completed state together in one database transaction."""
        with self.connect() as connection:
            export = self.create_export(values, connection=connection)
            stamp = now_iso()
            cursor = connection.execute(
                "UPDATE jobs SET state='completed', stage='persist_export', progress=1.0, "
                "checkpoint_json=?, updated_at=?, finished_at=COALESCE(finished_at, ?) "
                "WHERE id=? AND state IN ('queued','running')",
                (json.dumps({**checkpoint, 'export': export, 'files': values['metadata']['files']}, ensure_ascii=False), stamp, stamp, job_id),
            )
            if cursor.rowcount != 1:
                raise ValueError("EXPORT_JOB_NOT_ACTIVE")
            return export

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
        names = ["proxies", "detections", "review_clips", "previews"]
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
