"""Desktop contact-sheet preparation and transactional human shooter labels."""

from __future__ import annotations

import json
import threading
from contextlib import nullcontext
from pathlib import Path

from .adapters.analysis import PipelineCancelled
from .protocol import ProtocolError
from .storage import now_iso
from .release_preview import (
    cached_context,
    read_json,
    read_json_string,
    render_release_previews,
    source_fingerprint,
)


def persist_evidence(store, evidence, connection=None):
    with (
        store.connect() if connection is None else nullcontext(connection)
    ) as connection:
        for item in evidence:
            candidate = connection.execute(
                "SELECT event_time_ms, video_id FROM candidates WHERE id=?",
                (item["candidate_id"],),
            ).fetchone()
            if (
                not candidate
                or candidate["video_id"] != item["video_id"]
                or candidate["event_time_ms"] != item["event_time_ms"]
            ):
                raise ProtocolError(
                    "SHOOTER_CANDIDATES_CHANGED", "候选发生变化，请重新生成出手画面"
                )
            connection.execute(
                """INSERT INTO shooter_review_evidence
                (candidate_id,video_id,generation,source_fingerprint,evidence_json,updated_at)
                VALUES (?,?,?,?,?,?) ON CONFLICT(candidate_id) DO UPDATE SET
                generation=excluded.generation,source_fingerprint=excluded.source_fingerprint,
                evidence_json=excluded.evidence_json,updated_at=excluded.updated_at""",
                (
                    item["candidate_id"],
                    item["video_id"],
                    item["generation"],
                    json.dumps(item["source_fingerprint"], sort_keys=True),
                    json.dumps(item, ensure_ascii=False, allow_nan=False),
                    now_iso(),
                ),
            )


class ShooterReviewMixin:
    def list_shooter_review(self, payload):
        store = self._require_store(payload)
        with store.connect() as connection:
            saved = {
                row["candidate_id"]: dict(row)
                for row in connection.execute("SELECT * FROM shooter_review_evidence")
            }
        rows, sources = [], {}
        for candidate in store.list_candidates():
            row = saved.get(candidate["id"])
            evidence = json.loads(row["evidence_json"]) if row else None
            video = store.video(candidate["video_id"])
            stale = False
            if evidence and video:
                try:
                    if video["id"] not in sources:
                        source = Path(video["source_path"])
                        stat = source.stat()
                        sources[video["id"]] = {
                            "name": source.name,
                            "size": stat.st_size,
                            "mtime_ns": stat.st_mtime_ns,
                        }
                    stale = evidence["source_fingerprint"] != sources[video["id"]]
                except (ProtocolError, OSError):
                    stale = True
            selection = json.loads(row["selection_json"]) if row else {}
            review_state = row["review_state"] if row else "pending"
            if review_state == "confirmed" and candidate.get(
                "player_id"
            ) != selection.get("player_id"):
                review_state = "pending"
            rows.append(
                {
                    **candidate,
                    "shooter_evidence": None if stale else evidence,
                    "shooter_evidence_stale": stale,
                    "shooter_selection": selection,
                    "shooter_review_state": review_state,
                }
            )
        jobs = store.list_jobs(
            project_id=store.project()["id"], job_type="shooter_review", descending=True
        )
        history = store.list_jobs(
            store.project()["id"],
            job_type="analysis",
            descending=True,
        )
        analyses = [job for job in history if job["state"] in {"queued", "running"}]
        recent = jobs[:1] + [
            job
            for job in history[:1]
            if read_json_string(job.get("checkpoint_json")).get(
                "shooter_preview_manifest"
            )
        ]
        recent.sort(key=lambda job: job["created_at"], reverse=True)
        for analysis in analyses:
            checkpoint = read_json_string(analysis.get("checkpoint_json"))
            path = Path(checkpoint.get("shooter_preview_manifest") or "")
            if not path.is_file() or not path.resolve().is_relative_to(
                (store.root / "artifacts").resolve()
            ):
                continue
            draft = read_json(path, {})
            video = store.video(analysis["video_id"])
            try:
                valid = video and draft.get("source_fingerprint") == source_fingerprint(
                    Path(video["source_path"])
                )
            except OSError:
                valid = False
            if valid and draft.get("generation") == analysis["id"]:
                # Show one working set; committed data stays in SQLite.
                rows = [row for row in rows if row["video_id"] != analysis["video_id"]]
                rows.extend(
                    {**row, "draft": True, "shooter_review_state": "pending"}
                    for row in draft.get("candidates", [])
                )
        return {
            "candidates": rows,
            "players": store.list_players(),
            "videos": store.list_videos(),
            "jobs": analyses[:1] or recent[:1],
        }

    def prepare_shooter_review(self, payload):
        if payload.get("predictions_path") is not None:
            raise ProtocolError("INVALID_REQUEST", "当前版本仅支持从视频生成出手画面")
        with self._job_lock:
            self._job_threads = {
                k: t for k, t in self._job_threads.items() if t.is_alive()
            }
            store = self._require_store(payload)
            project = store.project()
            if self._job_threads or self._unfinished_heavy_jobs(store, project["id"]):
                raise ProtocolError(
                    "JOB_ALREADY_RUNNING", "请先完成或取消现有分析、导出或出手画面任务"
                )
            videos = [
                v
                for v in store.list_videos()
                if not payload.get("video_id") or v["id"] == payload["video_id"]
            ]
            if not videos:
                raise ProtocolError("VIDEO_NOT_FOUND", "没有可处理的视频")
            candidates = store.list_candidates()
            videos = [
                v for v in videos if any(c["video_id"] == v["id"] for c in candidates)
            ]
            if not videos:
                raise ProtocolError("SHOOTER_NO_CANDIDATES", "请先分析并生成候选片段")
            for video in videos:
                self._validated_source(video)
            result = {
                "job": store.create_job(
                    project["id"],
                    videos[0]["id"] if len(videos) == 1 else None,
                    "shooter_review",
                    {"video_ids": [v["id"] for v in videos]},
                )
            }
            job_id = result["job"]["id"]
            event = threading.Event()
            self._job_cancel_events[job_id] = event
            thread = threading.Thread(
                target=self._run_shooter_review,
                args=(dict(payload), job_id, videos, candidates),
                daemon=True,
                name=f"shooter-{job_id}",
            )
            self._job_threads[job_id] = thread
            try:
                thread.start()
            except RuntimeError:
                self._job_threads.pop(job_id, None)
                self._job_cancel_events.pop(job_id, None)
                store.update_job(
                    job_id,
                    state="failed",
                    error_code="SHOOTER_PREPARE_FAILED",
                    error_message="无法启动出手画面任务",
                )
                raise
            return result

    def _run_shooter_review(self, payload, job_id, videos, candidates):
        store = self._require_store(payload)
        cancel = self._job_cancel_events[job_id]
        directory = store.root / "artifacts/shooter_review" / job_id
        generated = []
        try:
            directory.mkdir(parents=True, exist_ok=True)
            for index, video in enumerate(videos):
                source = self._validated_source(video)
                rows = [c for c in candidates if c["video_id"] == video["id"]]
                destination = directory / video["id"]
                destination.mkdir()

                def progress(value, stage="shooter_frames"):
                    if cancel.is_set():
                        raise PipelineCancelled("JOB_CANCELLED")
                    store.update_job(
                        job_id,
                        state="running",
                        stage=stage,
                        progress=(index + value) / len(videos),
                    )

                progress(0.01)
                context = cached_context(store, video, source)
                generated.extend(
                    render_release_previews(
                        video,
                        source,
                        rows,
                        destination,
                        job_id,
                        proxy=context["proxy"],
                        offset_ms=context["offset_ms"],
                        coarse=context["coarse"],
                        cancel=cancel,
                        progress=progress,
                    )
                )
            if cancel.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            # All videos commit together only after every frame and identity check.
            persist_evidence(store, generated)
            store.update_job(job_id, state="completed", stage="completed", progress=1)
        except PipelineCancelled:
            store.update_job(
                job_id,
                state="cancelled",
                stage="cancelled",
                error_code="JOB_CANCELLED",
                error_message="已取消，保留原出手画面和人工标签",
            )
        except Exception as exc:
            store.update_job(
                job_id,
                state="failed",
                stage="shooter_review",
                error_code=exc.code
                if isinstance(exc, ProtocolError)
                else "SHOOTER_PREPARE_FAILED",
                error_message=str(exc),
            )
        finally:
            with self._job_lock:
                self._job_cancel_events.pop(job_id, None)
                self._job_threads.pop(job_id, None)

    def set_candidate_shooter(self, payload):
        store = self._require_store(payload)
        candidate_id = payload.get("candidate_id")
        state = payload.get("review_state", "confirmed")
        player_id, time_ms = payload.get("player_id"), payload.get("time_ms")
        if payload.get("track_id") is not None:
            raise ProtocolError("INVALID_REQUEST", "当前版本仅保存球员和出手帧")
        if state not in ("confirmed", "pending", "uncertain") or (
            state == "confirmed"
        ) != (isinstance(player_id, str) and bool(player_id)):
            raise ProtocolError(
                "INVALID_REQUEST", "请选择球员，或将此片段标为待标注/不确定"
            )
        with store.connect() as connection:
            row = connection.execute(
                "SELECT s.*,v.project_id FROM shooter_review_evidence s JOIN videos v ON v.id=s.video_id WHERE s.candidate_id=?",
                (candidate_id,),
            ).fetchone()
            if not row or payload.get("generation") != row["generation"]:
                raise ProtocolError(
                    "SHOOTER_EVIDENCE_CHANGED", "出手画面已更新，请刷新后重试"
                )
            evidence = json.loads(row["evidence_json"])
            video = store.video(row["video_id"])
            source = self._validated_source(video)
            stat = source.stat()
            if evidence["source_fingerprint"] != {
                "name": source.name,
                "size": stat.st_size,
                "mtime_ns": stat.st_mtime_ns,
            }:
                raise ProtocolError(
                    "SHOOTER_EVIDENCE_CHANGED", "原视频已重新关联，请重新生成出手画面"
                )
            if time_ms is not None and not any(
                f["time_ms"] == time_ms for f in evidence["frames"]
            ):
                raise ProtocolError("INVALID_REQUEST", "出手画面时间不匹配")
            if (
                player_id
                and not connection.execute(
                    "SELECT id FROM players WHERE id=? AND project_id=?",
                    (player_id, row["project_id"]),
                ).fetchone()
            ):
                raise ProtocolError("INVALID_REQUEST", "球员不属于当前项目")
            stamp = now_iso()
            connection.execute(
                """INSERT INTO candidate_reviews(candidate_id,player_id,status,updated_at)
                VALUES(?,?,'pending',?) ON CONFLICT(candidate_id) DO UPDATE SET
                player_id=excluded.player_id,updated_at=excluded.updated_at""",
                (candidate_id, player_id, stamp),
            )
            selection = {
                "generation": row["generation"],
                "time_ms": time_ms,
                "player_id": player_id,
            }
            connection.execute(
                "UPDATE shooter_review_evidence SET selection_json=?,review_state=?,updated_at=? WHERE candidate_id=?",
                (json.dumps(selection), state, stamp, candidate_id),
            )
        return {"updated": True, "selection": selection, "review_state": state}
