from __future__ import annotations

import json
import hashlib
import math
import os
import sqlite3
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict

from . import __version__
from .adapters.analysis import (
    build_pipeline_commands,
    candidate_to_row,
    flatten_coarse_matches,
    flatten_refined_matches,
    PipelineCancelled,
    run_pipeline,
    scale_roi_to_proxy,
    terminate_process,
)
from .adapters.export import export_goal_clips
from .protocol import ProtocolError
from .storage import ProjectStore, new_id
from basketball_highlight.tracking import link_ball_detections


ANALYSIS_ALGORITHM_VERSION = "python-v2.14-white-net-trajectory"


class EngineService:
    _MIN_PROCESSING_SPACE_BYTES = 512 * 1024 * 1024

    def __init__(self) -> None:
        self.stores: dict[str, ProjectStore] = {}
        self._job_threads: dict[str, threading.Thread] = {}
        self._job_cancel_events: dict[str, threading.Event] = {}
        self._job_processes: dict[str, set[subprocess.Popen]] = {}
        self._store_lock = threading.Lock()
        self._job_lock = threading.Lock()

    def shutdown(self, timeout: float = 5.0) -> None:
        with self._job_lock:
            thread_items = list(self._job_threads.items())
            cancel_events = list(self._job_cancel_events.values())
            processes = [
                process
                for job_processes in self._job_processes.values()
                for process in job_processes
            ]
        for event in cancel_events:
            event.set()
        for process in processes:
            terminate_process(process)
        deadline = time.monotonic() + max(0.0, timeout)
        for _, thread in thread_items:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            thread.join(remaining)
        unfinished = {
            job_id
            for job_id, thread in thread_items
            if thread.is_alive()
        }
        if unfinished:
            with self._store_lock:
                stores = list(self.stores.values())
            for store in stores:
                for job_id in unfinished:
                    job = store.get_job(job_id)
                    if job and job.get("state") in {"queued", "running"}:
                        store.update_job(
                            job_id,
                            state="cancelled",
                            stage="engine_shutdown",
                            error_code="JOB_CANCELLED",
                            error_message="应用关闭，任务已取消",
                        )

    def _handlers(self) -> dict[str, Any]:
        return {
            "hello": self.hello,
            "create_project": self.create_project,
            "update_project_settings": self.update_project_settings,
            "get_analysis_mode": self.get_analysis_mode,
            "set_analysis_mode": self.set_analysis_mode,
            "get_workflow_draft": self.get_workflow_draft,
            "save_workflow_draft": self.save_workflow_draft,
            "clear_workflow_draft": self.clear_workflow_draft,
            "open_project": self.open_project,
            "delete_project": self.delete_project,
            "list_recent_projects": self.list_recent_projects,
            "inspect_video": self.inspect_video,
            "link_video": self.link_video,
            "relink_video": self.relink_video,
            "extract_preview": self.extract_preview,
            "suggest_roi": self.suggest_roi,
            "save_roi": self.save_roi,
            "set_analysis_range": self.set_analysis_range,
            "start_analysis": self.start_analysis,
            "cancel_job": self.cancel_job,
            "get_job": self.get_job,
            "get_active_jobs": self.get_active_jobs,
            "get_latest_job": self.get_latest_job,
            "retry_analysis": self.retry_analysis,
            "retry_export": self.retry_export,
            "list_candidates": self.list_candidates,
            "create_manual_candidate": self.create_manual_candidate,
            "list_players": self.list_players,
            "create_player": self.create_player,
            "delete_player": self.delete_player,
            "set_candidate_player": self.set_candidate_player,
            "set_candidates_player": self.set_candidates_player,
            "start_review": self.start_review,
            "review_candidate": self.review_candidate,
            "list_review_history": self.list_review_history,
            "update_clip_range": self.update_clip_range,
            "start_export": self.start_export,
            "list_exports": self.list_exports,
            "get_statistics": self.get_statistics,
            "set_telemetry_consent": self.set_telemetry_consent,
            "cleanup_artifacts": self.cleanup_artifacts,
        }

    def handle(self, command: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        handler = self._handlers().get(command)
        if not handler:
            raise ProtocolError("INVALID_REQUEST", f"不支持的 command: {command}")
        return handler(payload)

    def hello(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "engine_version": __version__,
            "protocol_version": "1.0",
            "capabilities": list(self._handlers()),
            "analysis_runtime": ANALYSIS_ALGORITHM_VERSION,
        }

    def _store(self, payload: Dict[str, Any]) -> ProjectStore:
        root_path = payload.get("project_root") or payload.get("root_path")
        if not isinstance(root_path, str) or not root_path.strip():
            raise ProtocolError("INVALID_REQUEST", "缺少 project_root")
        key = str(Path(root_path).expanduser().resolve())
        with self._store_lock:
            store = self.stores.get(key)
            if store is None:
                store = ProjectStore(key)
                self.stores[key] = store
        store.initialize()
        return store

    def _existing_store(self, payload: Dict[str, Any]) -> tuple[ProjectStore, Dict[str, Any]]:
        root_path = payload.get("project_root") or payload.get("root_path")
        if not isinstance(root_path, str) or not root_path.strip():
            raise ProtocolError("INVALID_REQUEST", "缺少 project_root")
        root = Path(root_path).expanduser().resolve()
        if not root.is_dir() or not (root / "project.db").is_file():
            raise ProtocolError("PROJECT_NOT_FOUND", f"项目不存在: {root}")
        store = ProjectStore(root)
        try:
            context = store.context()
        except (OSError, sqlite3.Error, ValueError) as exc:
            raise ProtocolError("PROJECT_INVALID", f"项目数据库无效: {root}") from exc
        with self._store_lock:
            self.stores[str(store.root)] = store
        return store, context

    def _require_store(self, payload: Dict[str, Any]) -> ProjectStore:
        return self._existing_store(payload)[0]

    def create_project(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        name = payload.get("name")
        root_path = payload.get("root_path")
        if not isinstance(name, str) or not name.strip():
            raise ProtocolError("INVALID_REQUEST", "缺少项目名称")
        if not isinstance(root_path, str) or not root_path.strip():
            raise ProtocolError("INVALID_REQUEST", "缺少 root_path")
        store = self._store({"project_root": root_path})
        if store.project():
            raise ProtocolError("INVALID_REQUEST", "项目数据库已经存在")
        project = store.create_project(payload.get("project_id") or new_id("project"), name.strip(), payload.get("language", "zh-CN"))
        return {"project": project, "database_path": str(store.db_path)}

    def open_project(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        _, context = self._existing_store(payload)
        return context

    def delete_project(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        raw_root = payload.get("project_root") or payload.get("root_path")
        if not isinstance(raw_root, str) or not raw_root.strip():
            raise ProtocolError("INVALID_REQUEST", "缺少 project_root")
        candidate = Path(raw_root).expanduser()
        if candidate.is_symlink():
            raise ProtocolError("PROJECT_INVALID", "不允许删除符号链接项目")
        root = candidate.resolve()
        if root == root.parent or not root.is_dir() or not (root / "project.db").is_file():
            raise ProtocolError("PROJECT_NOT_FOUND", f"项目不存在: {root}")

        store, context = self._existing_store({"project_root": str(root)})
        project = context.get("project")
        project_id = project.get("id") if isinstance(project, dict) else None
        if not isinstance(project_id, str) or not project_id:
            raise ProtocolError("PROJECT_INVALID", f"项目数据库无效: {root}")

        for raw_source_path in store.video_source_paths():
            source_path = Path(raw_source_path).expanduser()
            if not source_path.is_absolute():
                source_path = root / source_path
            source_path = source_path.resolve()
            try:
                source_path.relative_to(root)
            except ValueError:
                continue
            raise ProtocolError(
                "PROJECT_SOURCE_INSIDE_PROJECT",
                "原始视频位于项目目录内，已拒绝删除项目以保护原始视频",
                {"source_path": str(source_path)},
            )

        with self._job_lock:
            active_jobs = store.list_jobs(
                project_id=project_id,
                states=("queued", "running"),
            )
            if active_jobs:
                raise ProtocolError(
                    "PROJECT_BUSY",
                    "项目仍有任务运行，请先取消任务后再删除",
                    {"job_ids": [job["id"] for job in active_jobs]},
                )

        try:
            shutil.rmtree(root)
        except OSError as exc:
            raise ProtocolError("PROJECT_DELETE_FAILED", f"项目删除失败: {exc}") from exc

        with self._store_lock:
            self.stores.pop(str(root), None)
        return {
            "deleted": True,
            "project_root": str(root),
            "project_id": project_id,
        }

    def update_project_settings(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store = self._require_store(payload)
        project = store.project()
        if not project:
            raise ProtocolError("PROJECT_INVALID", "项目尚未初始化")
        try:
            updated = store.update_project_settings(
                project["id"],
                name=payload.get("name"),
                theme_mode=payload.get("theme_mode"),
            )
        except (LookupError, ValueError) as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"project": updated}

    def get_analysis_mode(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        try:
            mode = self._require_store(payload).analysis_mode()
        except (LookupError, ValueError) as exc:
            raise ProtocolError("PROJECT_INVALID", str(exc)) from exc
        return {"mode": mode}

    def set_analysis_mode(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        mode = payload.get("mode")
        if mode not in {"fast", "standard"}:
            raise ProtocolError("ANALYSIS_MODE_INVALID", "分析模式必须是 fast 或 standard")
        try:
            saved = self._require_store(payload).set_analysis_mode(mode)
        except (LookupError, ValueError) as exc:
            raise ProtocolError("ANALYSIS_MODE_INVALID", str(exc)) from exc
        return {"mode": saved}

    def get_workflow_draft(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        try:
            draft = self._require_store(payload).workflow_draft()
        except (LookupError, ValueError) as exc:
            raise ProtocolError("WORKFLOW_DRAFT_INVALID", str(exc)) from exc
        return {"draft": draft}

    def save_workflow_draft(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        draft = payload.get("draft")
        if not isinstance(draft, dict):
            raise ProtocolError("WORKFLOW_DRAFT_INVALID", "配置草稿必须是对象")
        try:
            saved = self._require_store(payload).save_workflow_draft(draft)
        except (LookupError, ValueError) as exc:
            raise ProtocolError("WORKFLOW_DRAFT_INVALID", str(exc)) from exc
        return {"draft": saved}

    def clear_workflow_draft(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        try:
            self._require_store(payload).clear_workflow_draft()
        except (LookupError, ValueError) as exc:
            raise ProtocolError("WORKFLOW_DRAFT_INVALID", str(exc)) from exc
        return {"cleared": True}

    def list_recent_projects(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        roots = payload.get("roots")
        if not isinstance(roots, list) or not roots:
            raise ProtocolError("INVALID_REQUEST", "roots 必须是非空目录列表")
        if len(roots) > 16:
            raise ProtocolError("INVALID_REQUEST", "roots 数量不能超过 16")
        try:
            limit = int(payload.get("limit", 20))
        except (TypeError, ValueError) as exc:
            raise ProtocolError("INVALID_REQUEST", "limit 必须是整数") from exc
        if limit <= 0 or limit > 100:
            raise ProtocolError("INVALID_REQUEST", "limit 必须在 1 到 100 之间")

        scanned_roots: list[str] = []
        project_roots: list[Path] = []
        seen_roots: set[str] = set()
        for raw_root in roots:
            if not isinstance(raw_root, str) or not raw_root.strip():
                raise ProtocolError("INVALID_REQUEST", "roots 中的目录必须是非空字符串")
            root = Path(raw_root).expanduser().resolve()
            scanned_roots.append(str(root))
            if not root.is_dir():
                continue
            candidates = [root] if (root / "project.db").is_file() else []
            candidates.extend(
                child
                for child in root.iterdir()
                if child.is_dir() and not child.is_symlink() and (child / "project.db").is_file()
            )
            for candidate in candidates:
                key = str(candidate.resolve())
                if key not in seen_roots:
                    seen_roots.add(key)
                    project_roots.append(candidate.resolve())

        projects = []
        for project_root in project_roots:
            try:
                store, context = self._existing_store({"project_root": str(project_root)})
                modified_at = datetime.fromtimestamp(
                    store.db_path.stat().st_mtime,
                    tz=timezone.utc,
                ).isoformat(timespec="milliseconds")
            except (OSError, ProtocolError):
                continue
            projects.append({**context, "last_modified_at": modified_at})
        projects.sort(key=lambda item: item["last_modified_at"], reverse=True)
        return {"projects": projects[:limit], "scanned_roots": scanned_roots}

    def inspect_video(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        raw_path = payload.get("video_path")
        if not isinstance(raw_path, str) or not raw_path.strip():
            raise ProtocolError("INVALID_REQUEST", "缺少 video_path")
        path = Path(raw_path).expanduser().resolve()
        if not path.is_file():
            raise ProtocolError("VIDEO_NOT_FOUND", f"视频不存在: {path}")
        command = [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration,size:stream=index,codec_type,codec_name,width,height,r_frame_rate",
            "-of",
            "json",
            str(path),
        ]
        try:
            completed = subprocess.run(
                command,
                check=True,
                capture_output=True,
                stdin=subprocess.DEVNULL,
                text=True,
                timeout=30,
            )
            probe = json.loads(completed.stdout)
        except (
            OSError,
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
            json.JSONDecodeError,
        ) as exc:
            raise ProtocolError("VIDEO_OPEN_FAILED", f"无法读取视频元数据: {exc}") from exc
        if not isinstance(probe, dict):
            raise ProtocolError("VIDEO_OPEN_FAILED", "视频元数据格式无效")
        streams = probe.get("streams")
        if not isinstance(streams, list):
            raise ProtocolError("VIDEO_OPEN_FAILED", "视频流信息无效")
        video_stream = next(
            (item for item in streams if isinstance(item, dict) and item.get("codec_type") == "video"),
            None,
        )
        audio_stream = next(
            (item for item in streams if isinstance(item, dict) and item.get("codec_type") == "audio"),
            None,
        )
        if not video_stream:
            raise ProtocolError("VIDEO_FORMAT_UNSUPPORTED", "文件中没有视频流")
        try:
            width = int(video_stream.get("width"))
            height = int(video_stream.get("height"))
        except (TypeError, ValueError):
            raise ProtocolError("VIDEO_DIMENSION_INVALID", "视频分辨率无效")
        if width <= 0 or height <= 0:
            raise ProtocolError("VIDEO_DIMENSION_INVALID", "视频分辨率无效")
        fps = self._parse_ratio(video_stream.get("r_frame_rate"))
        format_data = probe.get("format")
        if not isinstance(format_data, dict):
            raise ProtocolError("VIDEO_OPEN_FAILED", "视频格式信息无效")
        try:
            duration = float(format_data.get("duration"))
        except (TypeError, ValueError):
            raise ProtocolError("VIDEO_OPEN_FAILED", "视频时长无效")
        if not math.isfinite(duration) or duration <= 0:
            raise ProtocolError("VIDEO_OPEN_FAILED", "视频时长无效")
        duration_ms = round(duration * 1000)
        disk = shutil.disk_usage(path.parent)
        estimated_processing_space = max(
            self._MIN_PROCESSING_SPACE_BYTES,
            round(path.stat().st_size * 0.20),
        )
        return {
            "source_path": str(path),
            "source_exists": True,
            "source_status": "linked",
            "file_name": path.name,
            "source_size_bytes": path.stat().st_size,
            "source_mtime_ns": path.stat().st_mtime_ns,
            "duration_ms": duration_ms,
            "width": width,
            "height": height,
            "fps": fps,
            "video_codec": video_stream.get("codec_name"),
            "audio_codec": audio_stream.get("codec_name") if audio_stream else None,
            "available_disk_bytes": disk.free,
            "estimated_processing_space_bytes": estimated_processing_space,
            "disk_space_sufficient": disk.free >= estimated_processing_space,
        }

    def _ensure_disk_space(self, workspace: Path, source: Path) -> None:
        if not source.is_file():
            return
        disk = shutil.disk_usage(workspace)
        required = max(
            self._MIN_PROCESSING_SPACE_BYTES,
            round(source.stat().st_size * 0.20),
        )
        if disk.free < required:
            raise ProtocolError(
                "DISK_SPACE_LOW",
                "可用磁盘空间不足，请清理缓存后重试",
                {
                    "available_bytes": disk.free,
                    "required_bytes": required,
                    "workspace": str(workspace),
                },
            )

    def _latest_proxy_video(self, store: ProjectStore, video_id: str) -> Path | None:
        project = store.project()
        video = store.video(video_id)
        if not project or not video:
            return None
        jobs = store.list_jobs(
            project_id=project["id"],
            job_type="analysis",
            states=("completed",),
            video_id=video_id,
        )
        source_path = str(Path(video["source_path"]).resolve())
        for job in reversed(jobs):
            checkpoint = self._decode_checkpoint(job)
            parameters = checkpoint.get("analysis_parameters")
            if isinstance(parameters, dict) and parameters.get("source_path") not in {None, source_path}:
                continue
            candidate = checkpoint.get("proxy_video")
            if not isinstance(candidate, str) or not candidate:
                continue
            path = Path(candidate).expanduser()
            if path.is_file() and path.stat().st_size > 0:
                return path.resolve()
        return None

    @staticmethod
    def _source_fingerprint(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        return f"{path.stat().st_size}:{digest.hexdigest()}"

    @classmethod
    def _validated_original_source(cls, video: Dict[str, Any]) -> Path:
        source = Path(video["source_path"])
        if not source.is_file():
            raise ProtocolError("VIDEO_NOT_FOUND", f"原始视频不存在: {source}")
        stat = source.stat()
        stored_size = video.get("source_size_bytes")
        stored_mtime = video.get("source_mtime_ns")
        stored_fingerprint = video.get("source_fingerprint")
        metadata_changed = (
            stored_size is not None
            and stored_mtime is not None
            and (
                int(stored_size) != stat.st_size
                or int(stored_mtime) != stat.st_mtime_ns
            )
        )
        content_changed = False
        if isinstance(stored_fingerprint, str) and stored_fingerprint:
            try:
                content_changed = stored_fingerprint != cls._source_fingerprint(source)
            except OSError:
                content_changed = True
        if metadata_changed or content_changed:
            raise ProtocolError(
                "VIDEO_SOURCE_CHANGED",
                "原视频内容已变化，请重新导入视频并校准篮筐区域",
            )
        return source

    _validated_source = _validated_original_source

    def suggest_roi(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        """Find a stable hoop in a short full-frame scan and suggest a ball ROI."""
        store = self._require_store(payload)
        video_id = payload.get("video_id")
        video = store.video(video_id) if isinstance(video_id, str) else None
        if not video:
            raise ProtocolError("VIDEO_NOT_FOUND", "自动 ROI 任务缺少有效视频")
        source = self._validated_source(video)

        repo_root = Path(__file__).resolve().parents[3]
        model_path = Path(
            payload.get("model_path")
            or self._default_model_path(repo_root)
        ).expanduser().resolve()
        if not model_path.is_file():
            raise ProtocolError("MODEL_LOAD_FAILED", f"模型不存在: {model_path}")

        try:
            sample_fps = float(payload.get("sample_fps", 1.0))
            duration = float(payload.get("duration", 20.0))
            max_samples = int(payload.get("max_samples", 12))
            confidence = float(payload.get("confidence", 0.05))
            start_ms = max(0.0, float(payload.get("start_ms", 0.0)))
        except (TypeError, ValueError) as exc:
            raise ProtocolError("INVALID_REQUEST", "自动 ROI 参数格式无效") from exc
        if (
            not math.isfinite(sample_fps)
            or sample_fps <= 0
            or not math.isfinite(duration)
            or duration <= 0
            or max_samples <= 0
            or not math.isfinite(confidence)
            or confidence <= 0
            or confidence >= 1
            or not math.isfinite(start_ms)
        ):
            raise ProtocolError("INVALID_REQUEST", "自动 ROI 参数必须在有效范围内")

        output = store.root / "artifacts" / "detections" / f"roi_suggestion_{video_id}.json"
        script = repo_root / "scripts" / "detect_auto_roi.py"
        command = [
            sys.executable,
            str(script),
            "--video",
            str(source),
            "--model",
            str(model_path),
            "--start",
            str(start_ms / 1000.0),
            "--output",
            str(output),
            "--sample-fps",
            str(sample_fps),
            "--duration",
            str(duration),
            "--max-samples",
            str(max_samples),
            "--conf",
            str(confidence),
        ]
        try:
            subprocess.run(
                command,
                check=True,
                capture_output=True,
                stdin=subprocess.DEVNULL,
                text=True,
                timeout=120,
            )
            result = json.loads(output.read_text(encoding="utf-8"))
        except (
            OSError,
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
            json.JSONDecodeError,
        ) as exc:
            raise ProtocolError("ROI_DETECTION_FAILED", f"自动 ROI 检测失败: {exc}") from exc

        if not result.get("success") or not isinstance(result.get("roi"), dict):
            raise ProtocolError(
                "ROI_NOT_FOUND",
                result.get("message") or "未自动定位到篮筐，请手动框选检测区域",
                {"suggestion": result},
            )
        roi = result["roi"]
        calibration = {
            "source": result.get("source", "auto_hoop_model"),
            "confidence": result.get("confidence"),
            "stability": result.get("stability"),
            "samples": result.get("samples"),
            "hoop_bbox": result.get("hoop_bbox"),
        }
        duration_ms = video.get("duration_ms")
        duration_limit = int(duration_ms) if duration_ms is not None else 1000
        return {
            "roi": roi,
            "calibration": calibration,
            "suggestion": result,
            "preview_time_ms": max(
                0,
                min(
                    int(result.get("preview_time_ms", 1000)),
                    duration_limit,
                ),
            ),
        }

    @staticmethod
    def _default_model_path(repo_root: Path) -> Path:
        tracked = repo_root / "models" / "bball_model.pt"
        if tracked.is_file():
            return tracked
        return repo_root / "third_party" / "basketball-shot-detection" / "bball_model.pt"

    @staticmethod
    def _parse_ratio(value: Any) -> float | None:
        if not isinstance(value, str) or "/" not in value:
            return None
        numerator, denominator = value.split("/", 1)
        try:
            ratio = float(numerator) / float(denominator)
        except (ValueError, ZeroDivisionError):
            return None
        return ratio if math.isfinite(ratio) and ratio > 0 else None

    def link_video(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        metadata = self.inspect_video(payload)
        store = self._require_store(payload)
        return {"video": store.link_video(metadata)}

    def relink_video(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        raw_path = payload.get("video_path")
        video_id = payload.get("video_id")
        if not isinstance(video_id, str) or not video_id:
            raise ProtocolError("INVALID_REQUEST", "缺少 video_id")
        if not isinstance(raw_path, str) or not raw_path.strip():
            raise ProtocolError("INVALID_REQUEST", "缺少 video_path")
        store = self._require_store(payload)
        if not store.video(video_id):
            raise ProtocolError("VIDEO_NOT_FOUND", "视频不存在")
        project = store.project()
        if not project:
            raise ProtocolError("PROJECT_INVALID", "项目尚未初始化")
        with self._job_lock:
            active = store.list_jobs(
                project_id=project["id"],
                states=("queued", "running"),
                video_id=video_id,
            )
            if active:
                raise ProtocolError(
                    "PROJECT_BUSY",
                    "视频仍有分析或导出任务运行，请先取消任务后再重新关联",
                    {"job_ids": [job["id"] for job in active]},
                )
        metadata = self.inspect_video({"video_path": raw_path})
        try:
            video = store.relink_video(video_id, metadata)
        except (LookupError, ValueError) as exc:
            raise ProtocolError("VIDEO_NOT_FOUND", str(exc)) from exc
        return {"video": video}

    def extract_preview(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store = self._require_store(payload)
        video_id = payload.get("video_id")
        video = store.video(video_id) if isinstance(video_id, str) else None
        if not video:
            raise ProtocolError("VIDEO_NOT_FOUND", "预览任务缺少有效视频")
        # Calibration and review previews share the original source coordinate system.
        source = self._validated_source(video)
        try:
            duration_ms = video.get("duration_ms")
            duration_limit = int(duration_ms) if duration_ms is not None else 1000
            time_ms = max(0, min(int(payload.get("time_ms", 1000)), duration_limit))
        except (TypeError, ValueError) as exc:
            raise ProtocolError("INVALID_REQUEST", "预览时间格式无效") from exc
        output = payload.get("output_path")
        output_path = Path(output).expanduser() if isinstance(output, str) and output.strip() else (
            self._preview_path(store, video, time_ms)
        )
        if not output_path.is_absolute():
            output_path = store.root / output_path
        output_path = output_path.resolve()
        if output_path.is_file() and output_path.stat().st_size > 0:
            return {"path": str(output_path), "time_ms": time_ms}
        output_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = output_path.with_name(
            f".{output_path.stem}.{os.getpid()}.tmp{output_path.suffix}"
        )
        command = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-ss", f"{time_ms / 1000:.3f}", "-i", str(source),
            "-frames:v", "1", "-vf", "scale=640:-2", "-q:v", "3", str(temporary_path),
        ]
        try:
            subprocess.run(
                command,
                check=True,
                capture_output=True,
                stdin=subprocess.DEVNULL,
                text=True,
                timeout=20,
            )
            temporary_path.replace(output_path)
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            temporary_path.unlink(missing_ok=True)
            raise ProtocolError("VIDEO_OPEN_FAILED", f"无法提取预览帧: {exc}") from exc
        if not output_path.is_file():
            raise ProtocolError("VIDEO_OPEN_FAILED", "预览帧未生成")
        return {"path": str(output_path), "time_ms": time_ms}

    @staticmethod
    def _preview_path(
        store: ProjectStore,
        video: Dict[str, Any],
        time_ms: int,
    ) -> Path:
        fingerprint = hashlib.sha256(
            (
                f"{video.get('source_size_bytes')}:{video.get('source_mtime_ns')}:"
                f"{video.get('source_path')}"
            ).encode("utf-8")
        ).hexdigest()[:12]
        return (
            store.root
            / "artifacts"
            / "previews"
            / f"{video['id']}_{fingerprint}_{max(0, int(time_ms))}ms.jpg"
        )

    def _prepare_candidate_previews(
        self,
        *,
        store: ProjectStore,
        source: Path,
        video: Dict[str, Any],
        video_id: str,
        rows: list[Dict[str, Any]],
        job_id: str,
        cancel_event: threading.Event | None,
    ) -> Dict[str, int]:
        preview_dir = store.root / "artifacts" / "previews"
        preview_dir.mkdir(parents=True, exist_ok=True)
        generated = 0
        reused = 0
        failed = 0
        total = max(1, len(rows))

        def prepare_one(index: int, row: Dict[str, Any]) -> str:
            if cancel_event and cancel_event.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            time_ms = max(0, int(row["event_time_ms"]))
            output_path = self._preview_path(store, video, time_ms)
            if output_path.is_file() and output_path.stat().st_size > 0:
                return "reused"
            temporary_path = output_path.with_name(
                f".{output_path.stem}.{job_id}.{index}.tmp{output_path.suffix}"
            )
            command = [
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                "-ss", f"{time_ms / 1000:.3f}", "-i", str(source),
                "-frames:v", "1", "-vf", "scale=640:-2", "-q:v", "3",
                str(temporary_path),
            ]
            popen_kwargs: Dict[str, Any] = {
                # 不继承 stdin,保护宿主 JSONL 管道(见 analysis.run_pipeline)。
                "stdin": subprocess.DEVNULL,
                "stdout": subprocess.PIPE,
                "stderr": subprocess.PIPE,
                "text": True,
            }
            if os.name == "nt":
                popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
            else:
                popen_kwargs["start_new_session"] = True
            process = subprocess.Popen(command, **popen_kwargs)
            self._set_job_process(job_id, process)
            try:
                while True:
                    try:
                        _, stderr = process.communicate(timeout=0.1)
                        break
                    except subprocess.TimeoutExpired:
                        if cancel_event and cancel_event.is_set():
                            terminate_process(process)
                            process.communicate()
                            raise PipelineCancelled("JOB_CANCELLED")
                if (
                    process.returncode == 0
                    and temporary_path.is_file()
                    and temporary_path.stat().st_size > 0
                ):
                    temporary_path.replace(output_path)
                    return "generated"
                if stderr:
                    print(
                        f"candidate preview failed at {time_ms}ms: {stderr[-500:]}",
                        file=sys.stderr,
                    )
                return "failed"
            finally:
                temporary_path.unlink(missing_ok=True)
                self._clear_job_process(job_id, process)

        with ThreadPoolExecutor(
            max_workers=min(2, max(1, len(rows))),
            thread_name_prefix=f"preview-{job_id}",
        ) as executor:
            futures = [
                executor.submit(prepare_one, index, row)
                for index, row in enumerate(rows)
            ]
            try:
                for future in as_completed(futures):
                    result = future.result()
                    if result == "generated":
                        generated += 1
                    elif result == "reused":
                        reused += 1
                    else:
                        failed += 1
                    completed = generated + reused + failed
                    store.update_job(
                        job_id,
                        state="running",
                        stage="prepare_review_previews",
                        progress=0.96 + 0.035 * (completed / total),
                    )
            except PipelineCancelled:
                if cancel_event:
                    cancel_event.set()
                for future in futures:
                    future.cancel()
                raise
        return {"generated": generated, "reused": reused, "failed": failed}

    def save_roi(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        required = ("video_id", "x1", "y1", "x2", "y2")
        missing = [key for key in required if key not in payload]
        if missing:
            raise ProtocolError("INVALID_REQUEST", f"缺少字段: {', '.join(missing)}")
        try:
            roi = self._require_store(payload).save_roi(payload["video_id"], payload)
        except (KeyError, LookupError, ValueError) as exc:
            raise ProtocolError("ROI_INVALID", str(exc)) from exc
        return {"roi": roi}

    def set_analysis_range(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        video_id = payload.get("video_id")
        if not isinstance(video_id, str) or not video_id:
            raise ProtocolError("VIDEO_NOT_FOUND", "缺少有效 video_id")
        try:
            start_ms = int(payload["start_ms"])
            end_ms = int(payload["end_ms"])
            video = self._require_store(payload).set_analysis_range(video_id, start_ms, end_ms)
        except (KeyError, TypeError, ValueError) as exc:
            raise ProtocolError("ANALYSIS_RANGE_INVALID", "分析范围无效") from exc
        except LookupError as exc:
            raise ProtocolError("VIDEO_NOT_FOUND", "视频不存在") from exc
        return {"video": video}

    def _create_analysis_job(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store = self._require_store(payload)
        project = store.project()
        if not project:
            raise ProtocolError("INVALID_REQUEST", "项目尚未初始化")
        video_id = payload.get("video_id")
        if not isinstance(video_id, str) or not store.video(video_id):
            raise ProtocolError("VIDEO_NOT_FOUND", "分析任务缺少有效视频")
        if not store.active_roi(video_id):
            raise ProtocolError("ROI_INVALID", "分析前必须保存篮筐 ROI")
        mode = payload.get("mode") or store.analysis_mode()
        if mode not in {"fast", "standard"}:
            raise ProtocolError("ANALYSIS_MODE_INVALID", "分析模式必须是 fast 或 standard")
        video = store.video(video_id)
        if video:
            source_for_space = Path(video["source_path"])
            self._ensure_disk_space(store.root, source_for_space)
        try:
            sample_fps = float(payload.get("sample_fps", 10))
            window_seconds = float(payload.get("window_seconds", 2.5))
            before_seconds = float(payload.get("before_seconds", 6))
            after_seconds = float(payload.get("after_seconds", 3))
        except (TypeError, ValueError) as exc:
            raise ProtocolError("INVALID_REQUEST", "分析参数格式无效") from exc
        if (
            not math.isfinite(sample_fps) or sample_fps <= 0
            or not math.isfinite(window_seconds) or window_seconds <= 0
            or not math.isfinite(before_seconds) or before_seconds < 0
            or not math.isfinite(after_seconds) or after_seconds <= 0
        ):
            raise ProtocolError("INVALID_REQUEST", "分析参数必须在有效范围内")
        analysis_start_ms = int(video.get("analysis_start_ms") or 0)
        analysis_end_ms = int(video.get("analysis_end_ms") or video.get("duration_ms") or 0)
        if analysis_end_ms <= analysis_start_ms:
            raise ProtocolError("ANALYSIS_RANGE_INVALID", "分析范围无效")
        checkpoint = {
            "mode": mode,
            "sample_fps": sample_fps,
            "window_seconds": window_seconds,
            "before_seconds": before_seconds,
            "after_seconds": after_seconds,
            "analysis_start_ms": analysis_start_ms,
            "analysis_end_ms": analysis_end_ms,
            "algorithm_version": ANALYSIS_ALGORITHM_VERSION,
        }
        store.set_analysis_mode(mode)
        return {"job": store.create_job(project["id"], video_id, "analysis", checkpoint)}

    @staticmethod
    def _unfinished_heavy_jobs(
        store: ProjectStore,
        project_id: str,
    ) -> list[Dict[str, Any]]:
        return [
            job
            for job in store.list_jobs(
                project_id=project_id,
                states=("queued", "running"),
            )
            if job.get("type") in {"analysis", "export"}
        ]

    def start_analysis(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        with self._job_lock:
            self._job_threads = {
                job_id: thread
                for job_id, thread in self._job_threads.items()
                if thread.is_alive()
            }
            if self._job_threads:
                raise ProtocolError("JOB_ALREADY_RUNNING", "已有重型任务正在运行")
            store = self._require_store(payload)
            project = store.project()
            if project:
                active = self._unfinished_heavy_jobs(store, project["id"])
                if active:
                    raise ProtocolError(
                        "JOB_RECOVERY_REQUIRED",
                        "项目存在未完成的分析或导出任务，请先恢复、重试或取消该任务",
                        {"job_ids": [item["id"] for item in active]},
                    )
            result = self._create_analysis_job(payload)
            job_id = result["job"]["id"]
            thread = threading.Thread(
                target=self._run_analysis,
                args=(dict(payload), job_id),
                name=f"analysis-{job_id}",
                daemon=True,
            )
            self._job_threads[job_id] = thread
            self._job_cancel_events[job_id] = threading.Event()
            try:
                thread.start()
            except RuntimeError as exc:
                self._job_threads.pop(job_id, None)
                self._job_cancel_events.pop(job_id, None)
                self._require_store(payload).update_job(
                    job_id, state="failed", stage="analysis",
                    error_code="ANALYSIS_FAILED", error_message=str(exc),
                )
                raise ProtocolError("ANALYSIS_FAILED", "无法启动分析任务") from exc
            return result

    def retry_analysis(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store = self._require_store(payload)
        job_id = payload.get("job_id")
        if not isinstance(job_id, str) or not job_id:
            raise ProtocolError("INVALID_REQUEST", "缺少 job_id")
        with self._job_lock:
            thread = self._job_threads.get(job_id)
            if thread and thread.is_alive():
                raise ProtocolError("JOB_ALREADY_RUNNING", "该分析任务仍在运行")
            job = store.get_job(job_id)
            if not job or job.get("type") != "analysis" or job.get("state") not in {
                "queued", "running", "failed", "cancelled",
            }:
                raise ProtocolError("JOB_NOT_FOUND", "没有可重试的分析任务")
            previous_checkpoint = self._decode_checkpoint(job)
            store.update_job(
                job_id,
                state="cancelled",
                stage="replaced_for_retry",
                error_code="JOB_RETRIED",
                error_message="用户发起重试，旧任务已结束",
                allow_terminal_transition=True,
            )
        retry_payload = dict(payload)
        retry_payload.pop("job_id", None)
        for key in (
            "mode",
            "sample_fps", "window_seconds", "before_seconds", "after_seconds",
            "proxy_width", "proxy_height", "proxy_fps", "coarse_scale",
            "refine_scale", "conf", "model_path",
        ):
            if key in retry_payload:
                continue
            if key in previous_checkpoint:
                retry_payload[key] = previous_checkpoint[key]
                continue
            parameters = previous_checkpoint.get("analysis_parameters", {})
            if isinstance(parameters, dict) and key in parameters:
                retry_payload[key] = parameters[key]
        return self.start_analysis(retry_payload)

    def retry_export(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store = self._require_store(payload)
        job_id = payload.get("job_id")
        if not isinstance(job_id, str) or not job_id:
            raise ProtocolError("INVALID_REQUEST", "缺少 job_id")
        with self._job_lock:
            thread = self._job_threads.get(job_id)
            if thread and thread.is_alive():
                raise ProtocolError("JOB_ALREADY_RUNNING", "该导出任务仍在运行")
        job = store.get_job(job_id)
        if not job or job.get("type") != "export":
            raise ProtocolError("JOB_NOT_FOUND", "导出任务不存在")
        if job.get("state") not in {"failed", "cancelled", "running", "queued"}:
            raise ProtocolError("INVALID_REQUEST", "当前导出任务不可重试")
        if job.get("state") in {"running", "queued"}:
            store.update_job(
                job_id,
                state="cancelled",
                stage="replaced_for_retry",
                error_code="JOB_RETRIED",
                error_message="用户发起重试，旧任务已结束",
                allow_terminal_transition=True,
            )
        checkpoint = self._decode_checkpoint(job)
        retry_payload = {
            "project_root": str(store.root),
            "video_id": job.get("video_id"),
            "mode": checkpoint.get("mode", "standard"),
        }
        if checkpoint.get("output_dir") is not None:
            retry_payload["output_dir"] = checkpoint["output_dir"]
        if checkpoint.get("output_path") is not None:
            retry_payload["output_path"] = checkpoint["output_path"]
        return self.start_export(retry_payload)

    @staticmethod
    def _refined_fallback_overlay(
        match: Dict[str, Any],
        fallback: Dict[str, Any],
    ) -> Dict[str, Any] | None:
        """用精化阶段已扫出的高清轨迹(source 坐标)为兜底候选合成 overlay。

        精化验证失败只是"轨迹串联不出穿框",窗口内的高清球检测依然
        有效;轨迹与 rim 都已是源视频坐标,无需缩放。
        """
        traj = fallback.get("trajectory") or []
        rim = fallback.get("rim") or {}
        if len(traj) < 3 or "rim_y" not in rim or "center_x" not in rim:
            return None
        rim_y = float(rim["rim_y"])
        crossing = None
        for a, b in zip(traj, traj[1:]):
            span = float(b["y"]) - float(a["y"])
            if abs(span) > 1e-6 and float(a["y"]) <= rim_y <= float(b["y"]):
                t = (rim_y - float(a["y"])) / span
                crossing = {
                    "x": round(
                        float(a["x"]) + (float(b["x"]) - float(a["x"])) * t, 1
                    ),
                    "y": round(rim_y, 1),
                    "time": round(
                        float(a["time"])
                        + (float(b["time"]) - float(a["time"])) * t,
                        3,
                    ),
                    "valid": False,
                }
                break
        return {
            "rim": {
                "center_x": round(float(rim.get("center_x", 0.0)), 1),
                "rim_y": round(rim_y, 1),
                "width": round(float(rim.get("width", 0.0)), 1),
                "height": round(float(rim.get("height", 0.0)) * 0.45, 1),
            },
            "trajectory": traj,
            "crossing": crossing,
            "source": "refined_fallback",
        }

    @staticmethod
    def _coarse_overlay(
        match: Dict[str, Any],
        rim: Dict[str, Any],
        factor: float,
        records: list | None = None,
    ) -> Dict[str, Any] | None:
        """为粗扫兜底候选合成最小可视化 overlay。

        粗扫没有 refine 轨迹,但保留了构成穿框的两次检测(above/below)
        和粗扫 rim 估计;按 proxy->source 比例缩放后供审核页画出
        篮筐框、轨迹与推定穿框点(黄色,valid=False)。轨迹优先取
        穿越前后 ±1.5s 的真实球检测(多点),否则退化为起止两点。
        """
        above = match.get("above")
        below = match.get("below")
        if not isinstance(above, dict) or not isinstance(below, dict):
            return None
        required_point_fields = ("time", "x", "y")
        if any(
            field not in point
            for point in (above, below)
            for field in required_point_fields
        ):
            return None

        def scaled(point: Dict[str, Any]) -> Dict[str, float]:
            return {
                "time": round(float(point.get("time", 0.0) or 0.0), 3),
                "x": round(float(point.get("x", 0.0) or 0.0) * factor, 1),
                "y": round(float(point.get("y", 0.0) or 0.0) * factor, 1),
            }

        rim_width = float(rim.get("width", 0.0) or 0.0) * factor
        rim_height = float(rim.get("height", 0.0) or 0.0) * factor
        rim_center_x = float(rim.get("center_x", 0.0) or 0.0) * factor
        rim_raw_y = float(rim.get("rim_y", 0.0) or 0.0) * factor
        # 与 refine 的 hoop_box_plane 校正一致:YOLO 篮筐框中心偏下,
        # 取框上部为筐口平面。
        plane_y = rim_raw_y - rim_height * 0.28

        event_time = float(match.get("time", 0.0) or 0.0)
        # 从构成候选的 above 真检测双向关联。每帧只取真正最近点，
        # 且门限按筐宽归一化，避免检测顺序和视频尺度改变轨迹。
        chain = link_ball_detections(
            records or [],
            anchor=above,
            rim_width=float(rim.get("width", 0.0) or 0.0),
            start_time=event_time - 1.5,
            end_time=event_time + 1.5,
        )
        trajectory = [
            {
                "time": round(point["time"], 3),
                "x": round(point["x"] * factor, 1),
                "y": round(point["y"] * factor, 1),
            }
            for point in chain
        ]
        if len(trajectory) < 3:
            a = scaled(above)
            b = scaled(below)
            trajectory = [a, b]

        crossing = None
        above_point = scaled(above)
        below_point = scaled(below)
        span = below_point["y"] - above_point["y"]
        if abs(span) > 1e-6 and above_point["y"] <= plane_y <= below_point["y"]:
            t = (plane_y - above_point["y"]) / span
            crossing = {
                "x": round(
                    above_point["x"] + (below_point["x"] - above_point["x"]) * t, 1
                ),
                "y": round(plane_y, 1),
                "time": round(
                    above_point["time"]
                    + (below_point["time"] - above_point["time"]) * t,
                    3,
                ),
                "valid": False,
            }
        return {
            "rim": {
                "center_x": round(rim_center_x, 1),
                "rim_y": round(plane_y, 1),
                "width": round(rim_width, 1),
                "height": round(rim_height * 0.45, 1),
            },
            "trajectory": trajectory,
            "crossing": crossing,
            "source": "coarse_crossing",
        }

    def _run_analysis(self, payload: Dict[str, Any], job_id: str) -> None:
        store = self._require_store(payload)
        analysis_started = time.perf_counter()
        checkpoint: Dict[str, Any] = {}

        def checkpoint_with_elapsed() -> Dict[str, Any]:
            return {
                **checkpoint,
                "total_elapsed_ms": round(
                    (time.perf_counter() - analysis_started) * 1000
                ),
            }

        try:
            video_id = payload["video_id"]
            video = store.video(video_id)
            roi = store.active_roi(video_id)
            if not video or not roi:
                raise ProtocolError("VIDEO_NOT_FOUND", "分析任务数据已失效")
            # Analysis and review currently share the linked source video.
            # Keep this explicit: the review/export path must never fall back
            # to an analysis proxy unless a future working-video field is
            # added to the persisted video contract.
            source_video = self._validated_source(video)
            repo_root = Path(__file__).resolve().parents[3]
            model_path = Path(payload.get("model_path") or self._default_model_path(repo_root)).expanduser().resolve()
            if not model_path.is_file():
                raise ProtocolError("MODEL_LOAD_FAILED", f"模型不存在: {model_path}")
            mode = payload.get("mode", "standard")
            if mode not in {"fast", "standard"}:
                raise ProtocolError("ANALYSIS_MODE_INVALID", "分析模式必须是 fast 或 standard")
            if mode == "fast":
                proxy_width = 640
                proxy_height = 480
                proxy_fps = 3.0
            else:
                proxy_width = int(payload.get("proxy_width", 960))
                proxy_height = int(payload.get("proxy_height", 720))
                proxy_fps = float(payload.get("proxy_fps", 5))
            source_width = int(video.get("width") or 0)
            source_height = int(video.get("height") or 0)
            if source_width <= 0 or source_height <= 0:
                raise ProtocolError("VIDEO_DIMENSION_INVALID", "视频分辨率无效")
            proxy_fit_scale = min(
                proxy_width / source_width,
                proxy_height / source_height,
            )
            proxy_scale = 1.0 / proxy_fit_scale
            source_roi = [roi[key] for key in ("x1", "y1", "x2", "y2")]
            calibration = roi.get("calibration") if isinstance(roi.get("calibration"), dict) else {}
            raw_net_roi = calibration.get("net_roi") if isinstance(calibration, dict) else None
            net_roi = None
            if isinstance(raw_net_roi, dict):
                try:
                    net_roi = [float(raw_net_roi[key]) for key in ("x1", "y1", "x2", "y2")]
                except (KeyError, TypeError, ValueError):
                    net_roi = None
            proxy_roi = scale_roi_to_proxy(
                roi,
                source_width,
                proxy_width,
                source_height=source_height,
                proxy_height=proxy_height,
            )
            analysis_parameters = {
                "algorithm_version": ANALYSIS_ALGORITHM_VERSION,
                "mode": mode,
                "source_path": str(source_video),
                "source_size_bytes": video.get("source_size_bytes"),
                "source_mtime_ns": video.get("source_mtime_ns"),
                "model_path": str(model_path),
                "model_mtime_ns": model_path.stat().st_mtime_ns,
                "roi": source_roi,
                "net_roi": net_roi,
                "proxy_width": proxy_width,
                "proxy_height": proxy_height,
                "proxy_fps": proxy_fps,
                "window_seconds": float(payload.get("window_seconds", 2.5)),
                "coarse_scale": int(payload.get("coarse_scale", 4)),
                "sample_fps": float(payload.get("sample_fps", 10)),
                "refine_scale": int(payload.get("refine_scale", 2)),
                "conf": float(payload.get("conf", 0.10)),
                "before_seconds": float(payload.get("before_seconds", 6)),
                "after_seconds": float(payload.get("after_seconds", 3)),
                "analysis_start_ms": int(video.get("analysis_start_ms") or 0),
                "analysis_end_ms": int(video.get("analysis_end_ms") or video.get("duration_ms") or 0),
            }
            analysis_key = hashlib.sha256(
                json.dumps(analysis_parameters, ensure_ascii=False, sort_keys=True).encode("utf-8")
            ).hexdigest()[:16]
            artifact_root = store.root / "artifacts"
            run_root = artifact_root / "detections" / f"{video_id}_{analysis_key}"
            proxy_video = artifact_root / "proxies" / f"{video_id}_{analysis_key}.mp4"
            coarse_detections = run_root / "coarse.json"
            coarse_candidates = run_root / "candidates.json"
            refined_output = run_root / "refined.json"
            manifest_path = run_root / "manifest.json"
            cache_dir = run_root / "cache"
            commands = build_pipeline_commands(
                repo_root=repo_root,
                source_video=source_video,
                proxy_video=proxy_video,
                model_path=model_path,
                coarse_detections=coarse_detections,
                coarse_candidates=coarse_candidates,
                refined_output=refined_output,
                proxy_roi=proxy_roi,
                source_roi=source_roi,
                cache_dir=cache_dir,
                proxy_width=proxy_width,
                proxy_height=proxy_height,
                proxy_fps=proxy_fps,
                coarse_scale=int(payload.get("coarse_scale", 4)),
                proxy_scale=proxy_scale,
                refine_sample_fps=float(payload.get("sample_fps", 10)),
                refine_scale=int(payload.get("refine_scale", 2)),
                conf=float(payload.get("conf", 0.10)),
                window_seconds=float(payload.get("window_seconds", 2.5)),
                analysis_start_ms=int(video.get("analysis_start_ms") or 0),
                analysis_end_ms=int(video.get("analysis_end_ms") or video.get("duration_ms") or 0),
                net_roi=net_roi,
                include_refinement=mode == "standard",
            )

            checkpoint = {
                "mode": mode,
                "analysis_key": analysis_key,
                "analysis_parameters": analysis_parameters,
                "proxy_video": str(proxy_video),
                "coarse_detections": str(coarse_detections),
                "coarse_candidates": str(coarse_candidates),
                "refined_output": str(refined_output),
                "manifest": str(manifest_path),
            }

            def on_stage(stage: str, progress: float) -> None:
                store.update_job(
                    job_id,
                    state="running",
                    stage=stage,
                    progress=progress,
                    checkpoint=checkpoint,
                )

            store.update_job(
                job_id,
                state="running",
                stage="validate_input",
                progress=0.01,
                checkpoint=checkpoint,
            )
            cancel_event = self._job_cancel_events.get(job_id)
            pipeline = run_pipeline(
                commands,
                refined_output if mode == "standard" else coarse_candidates,
                on_stage,
                cancel_check=cancel_event.is_set if cancel_event else None,
                process_callback=lambda process: self._set_job_process(job_id, process),
                manifest_path=manifest_path,
                stage_outputs=(
                    [proxy_video, coarse_detections, coarse_candidates]
                    if mode == "fast"
                    else [proxy_video, coarse_detections, coarse_candidates, refined_output]
                ),
                manifest_version=ANALYSIS_ALGORITHM_VERSION,
            )
            if cancel_event and cancel_event.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            matches = (
                flatten_refined_matches(pipeline["refined"])
                if mode == "standard"
                else flatten_coarse_matches(pipeline["refined"])
            )
            if mode == "standard":
                # 高召回兜底:refine 轨迹验证失败(移动机位下易发生)的
                # 粗扫穿框不丢弃,以粗扫证据保留为待审核候选,交给用户
                # 确认/排除。±2s 内已有 refined 结果的不再重复保留。
                try:
                    coarse_data = json.loads(
                        Path(coarse_candidates).read_text(encoding="utf-8")
                    )
                    coarse_matches = flatten_coarse_matches(coarse_data)
                except (OSError, ValueError):
                    coarse_matches = []
                refined_times = [float(match["time"]) for match in matches]
                coarse_rim = coarse_data.get("rim") if isinstance(coarse_data, dict) else None
                if not isinstance(coarse_rim, dict):
                    coarse_rim = {}
                # 粗扫坐标是代理视频像素,合成 overlay 时缩放到源视频。
                proxy_factor = proxy_scale if proxy_scale > 0 else 1.0
                # 粗扫检测记录:为兜底候选的轨迹带上穿越前后的真实
                # 检测点(而非只有起止两点),配合平滑渲染呈现弧线。
                coarse_records = []
                try:
                    scan_data = json.loads(
                        Path(coarse_detections).read_text(encoding="utf-8")
                    )
                    coarse_records = scan_data.get("records", [])
                except (OSError, ValueError):
                    coarse_records = []
                # 精化验证失败但已扫出的高清轨迹(source 坐标),
                # 供兜底候选直接使用,优于粗扫稀疏轨迹。
                refined_fallbacks: list[dict] = []
                pipeline_refined = pipeline.get("refined") or {}
                if isinstance(pipeline_refined, dict):
                    for result in pipeline_refined.get("results", []):
                        if not isinstance(result, dict):
                            continue
                        traj = result.get("fallback_trajectory")
                        coarse_entry = result.get("coarse") or {}
                        if (
                            isinstance(traj, list)
                            and len(traj) >= 3
                            and isinstance(coarse_entry, dict)
                            and "time" in coarse_entry
                        ):
                            refined_fallbacks.append(
                                {
                                    "time": float(coarse_entry["time"]),
                                    "trajectory": traj,
                                    "rim": result.get("rim_local") or {},
                                }
                            )
                for extra in coarse_matches:
                    extra_time = float(extra["time"])
                    if any(
                        abs(extra_time - refined_time) <= 2.0
                        for refined_time in refined_times
                    ):
                        continue
                    # 优先使用精化阶段已扫出的高清轨迹;不可用时退回
                    # 粗扫记录的速度门限串联轨迹。
                    overlay = None
                    for fallback in refined_fallbacks:
                        if abs(fallback["time"] - extra_time) <= 1.0:
                            overlay = self._refined_fallback_overlay(
                                extra, fallback,
                            )
                            break
                    if overlay is None:
                        overlay = self._coarse_overlay(
                            extra,
                            extra.get("rim")
                            if isinstance(extra.get("rim"), dict)
                            else coarse_rim,
                            proxy_factor,
                            records=coarse_records,
                        )
                    if overlay is not None:
                        extra["overlay"] = overlay
                    matches.append(extra)
                matches.sort(key=lambda match: float(match["time"]))
            detection_counts = self._detection_counts(coarse_detections)
            rows = [
                candidate_to_row(
                    match,
                    video_id=video_id,
                    roi_id=roi["id"],
                    duration_ms=int(video.get("duration_ms") or 0),
                    before_seconds=float(payload.get("before_seconds", 6)),
                    after_seconds=float(payload.get("after_seconds", 3)),
                    detector_version=f"{ANALYSIS_ALGORITHM_VERSION}:{mode}",
                    analysis_source=(
                        "coarse"
                        if mode == "fast" or match.get("coarse_crossing")
                        else "refined"
                    ),
                )
                for match in matches
            ]
            if not rows and detection_counts.get("ball", 0) == 0:
                raise ProtocolError(
                    "NO_BALL_DETECTIONS",
                    "分析完成但未检测到篮球，请扩大 ROI 或检查视频画面",
                    {"detection_counts": detection_counts},
                )
            store.update_job(
                job_id,
                state="running",
                stage="prepare_review_previews",
                progress=0.96,
            )
            eager_preview_rows = rows[:12]
            preview_started = time.perf_counter()
            preview_counts = self._prepare_candidate_previews(
                store=store,
                source=source_video,
                video=video,
                video_id=video_id,
                rows=eager_preview_rows,
                job_id=job_id,
                cancel_event=cancel_event,
            )
            stage_timings_ms = dict(pipeline.get("stage_timings_ms", {}))
            stage_timings_ms["prepare_review_previews"] = round(
                (time.perf_counter() - preview_started) * 1000
            )
            preview_counts["deferred"] = len(rows) - len(eager_preview_rows)
            if cancel_event and cancel_event.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            persist_started = time.perf_counter()
            store.replace_candidates(video_id, rows)
            stage_timings_ms["persist_candidates"] = round(
                (time.perf_counter() - persist_started) * 1000
            )
            checkpoint = {
                **checkpoint,
                "candidate_count": len(rows),
                "detection_counts": detection_counts,
                "preview_counts": preview_counts,
                "logs": pipeline["logs"],
                "cache_hits": pipeline.get("cache_hits", 0),
                "stage_timings_ms": stage_timings_ms,
                "total_elapsed_ms": round(
                    (time.perf_counter() - analysis_started) * 1000
                ),
            }
            store.update_job(job_id, state="completed", stage="persist_candidates", progress=1.0, checkpoint=checkpoint)
        except PipelineCancelled:
            store.update_job(
                job_id,
                state="cancelled",
                stage="analysis",
                error_code="JOB_CANCELLED",
                error_message="任务已取消",
                checkpoint=checkpoint_with_elapsed(),
            )
        except ProtocolError as exc:
            store.update_job(
                job_id,
                state="failed",
                stage="analysis",
                error_code=exc.code,
                error_message=exc.message,
                checkpoint=checkpoint_with_elapsed(),
            )
        except Exception as exc:
            store.update_job(
                job_id,
                state="failed",
                stage="analysis",
                error_code="ANALYSIS_FAILED",
                error_message=str(exc),
                checkpoint=checkpoint_with_elapsed(),
            )
        finally:
            with self._job_lock:
                self._job_threads.pop(job_id, None)
                self._job_cancel_events.pop(job_id, None)
                self._job_processes.pop(job_id, None)

    def _set_job_process(self, job_id: str, process: subprocess.Popen | None) -> None:
        with self._job_lock:
            if process is None:
                self._job_processes.pop(job_id, None)
            else:
                self._job_processes.setdefault(job_id, set()).add(process)

    def _clear_job_process(
        self,
        job_id: str,
        process: subprocess.Popen | None,
    ) -> None:
        with self._job_lock:
            if process is None:
                self._job_processes.pop(job_id, None)
                return
            processes = self._job_processes.get(job_id)
            if not processes:
                return
            processes.discard(process)
            if not processes:
                self._job_processes.pop(job_id, None)

    @staticmethod
    def _detection_counts(path: Path) -> dict[str, int]:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        counts: dict[str, int] = {}
        for record in data.get("records", []):
            for detection in record.get("detections", []):
                name = str(detection.get("name", "unknown")).lower()
                counts[name] = counts.get(name, 0) + 1
        return counts

    def cancel_job(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store = self._require_store(payload)
        job_id = payload.get("job_id")
        if not isinstance(job_id, str) or not job_id:
            raise ProtocolError("INVALID_REQUEST", "缺少 job_id")
        job = store.get_job(job_id)
        if not job:
            raise ProtocolError("JOB_NOT_FOUND", "任务不存在")
        if job["state"] in {"completed", "failed", "cancelled"}:
            return {"job": job}
        with self._job_lock:
            cancel_event = self._job_cancel_events.get(job_id)
            processes = set(self._job_processes.get(job_id, set()))
            if cancel_event:
                cancel_event.set()
            should_persist = not cancel_event and not processes
        # Do not hold _job_lock while waiting for the process group. The
        # worker needs the same lock to clear its process handle in finally.
        for process in processes:
            terminate_process(process)
        if cancel_event or processes:
            job = store.update_job(
                job_id,
                state=job["state"],
                stage="cancelling",
            )
        elif should_persist:
            job = store.update_job(
                job_id,
                state="cancelled",
                stage="cancelled",
                error_code="JOB_CANCELLED",
                error_message="任务已取消",
            )
        return {"job": store.get_job(job_id) or job}

    def get_job(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store = self._require_store(payload)
        job = store.get_job(payload.get("job_id", ""))
        if not job:
            raise ProtocolError("JOB_NOT_FOUND", "任务不存在")
        return {"job": job}

    @staticmethod
    def _decode_checkpoint(job: Dict[str, Any]) -> Dict[str, Any]:
        raw_checkpoint = job.get("checkpoint_json")
        if not raw_checkpoint:
            return {}
        try:
            checkpoint = json.loads(raw_checkpoint)
        except (TypeError, json.JSONDecodeError):
            return {"_raw": raw_checkpoint}
        return checkpoint if isinstance(checkpoint, dict) else {"value": checkpoint}

    def get_active_jobs(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store, context = self._existing_store(payload)
        project = context.get("project")
        if not project:
            raise ProtocolError("PROJECT_INVALID", "项目尚未初始化")

        video_id = payload.get("video_id")
        if video_id is not None:
            if not isinstance(video_id, str) or not video_id:
                raise ProtocolError("INVALID_REQUEST", "video_id 必须是非空字符串")
            if not store.video(video_id):
                raise ProtocolError("VIDEO_NOT_FOUND", "视频不存在")

        job_type = payload.get("job_type", "analysis")
        if job_type not in {"analysis", "export"}:
            raise ProtocolError("INVALID_REQUEST", "job_type 只支持 analysis 或 export")

        jobs = store.list_jobs(
            project_id=project["id"],
            job_type=job_type,
            states=("queued", "running"),
            video_id=video_id,
        )
        with self._job_lock:
            live_job_ids = {
                job_id
                for job_id, thread in self._job_threads.items()
                if thread.is_alive()
            }

        active_jobs: list[Dict[str, Any]] = []
        for job in jobs:
            if job["id"] in live_job_ids:
                runtime_state = "running"
                recovery_state = "worker_attached"
                recoverable = False
            elif job["state"] == "running":
                runtime_state = "stale"
                recovery_state = "stale_recoverable"
                recoverable = True
            else:
                runtime_state = "queued"
                recovery_state = "queued_recoverable"
                recoverable = True
            active_jobs.append(
                {
                    **job,
                    "checkpoint": self._decode_checkpoint(job),
                    "runtime_state": runtime_state,
                    "recovery_state": recovery_state,
                    "recoverable": recoverable,
                }
            )
        return {"jobs": active_jobs, "count": len(active_jobs)}

    def get_latest_job(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store, context = self._existing_store(payload)
        project = context.get("project")
        if not project:
            raise ProtocolError("PROJECT_INVALID", "项目尚未初始化")

        video_id = payload.get("video_id")
        if video_id is not None:
            if not isinstance(video_id, str) or not video_id:
                raise ProtocolError("INVALID_REQUEST", "video_id 必须是非空字符串")
            if not store.video(video_id):
                raise ProtocolError("VIDEO_NOT_FOUND", "视频不存在")

        job_type = payload.get("job_type", "analysis")
        if job_type not in {"analysis", "export"}:
            raise ProtocolError("INVALID_REQUEST", "job_type 只支持 analysis 或 export")

        jobs = store.list_jobs(
            project_id=project["id"],
            job_type=job_type,
            video_id=video_id,
            descending=True,
        )
        if not jobs:
            return {"job": None}
        job = jobs[0]
        return {"job": {**job, "checkpoint": self._decode_checkpoint(job)}}

    def list_candidates(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store, context = self._existing_store(payload)
        video_id = payload.get("video_id")
        candidates = store.list_candidates(video_id)
        video = store.video(video_id) if isinstance(video_id, str) else None
        if video:
            for candidate in candidates:
                preview_path = self._preview_path(
                    store,
                    video,
                    int(candidate.get("event_time_ms") or 0),
                )
                if preview_path.is_file() and preview_path.stat().st_size > 0:
                    candidate["preview_path"] = str(preview_path)
        review_video_path = (
            str(Path(video["source_path"]).resolve())
            if context.get("project") and video
            else None
        )
        return {
            "candidates": candidates,
            "review_video_path": review_video_path,
            "players": store.list_players(),
        }

    def create_manual_candidate(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        video_id = payload.get("video_id")
        if not isinstance(video_id, str) or not video_id:
            raise ProtocolError("INVALID_REQUEST", "缺少 video_id")
        try:
            start_ms = int(payload["start_ms"])
            end_ms = int(payload["end_ms"])
            event_time_ms = payload.get("event_time_ms")
            event_time_ms = None if event_time_ms is None else int(event_time_ms)
            candidate = self._require_store(payload).create_manual_candidate(
                video_id,
                start_ms,
                end_ms,
                event_time_ms,
            )
        except KeyError as exc:
            raise ProtocolError("INVALID_REQUEST", f"缺少字段: {exc.args[0]}") from exc
        except (TypeError, ValueError, LookupError) as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"candidate": candidate}

    def list_players(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        return {"players": self._require_store(payload).list_players()}

    def create_player(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        name = payload.get("name")
        if not isinstance(name, str):
            raise ProtocolError("INVALID_REQUEST", "缺少球员名称")
        try:
            player = self._require_store(payload).create_player(name)
        except ValueError as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"player": player}

    def delete_player(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        player_id = payload.get("player_id")
        if not isinstance(player_id, str) or not player_id:
            raise ProtocolError("INVALID_REQUEST", "缺少 player_id")
        try:
            self._require_store(payload).delete_player(player_id)
        except (ValueError, LookupError) as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"deleted": True}

    def set_candidate_player(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        candidate_id = payload.get("candidate_id")
        if not isinstance(candidate_id, str) or not candidate_id:
            raise ProtocolError("INVALID_REQUEST", "缺少 candidate_id")
        player_id = payload.get("player_id")
        if player_id is not None and (not isinstance(player_id, str) or not player_id):
            raise ProtocolError("INVALID_REQUEST", "player_id 必须是字符串或 null")
        try:
            self._require_store(payload).set_candidate_player(candidate_id, player_id)
        except (ValueError, LookupError) as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"updated": True}

    def set_candidates_player(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        candidate_ids = payload.get("candidate_ids")
        if not isinstance(candidate_ids, list) or not all(isinstance(item, str) and item for item in candidate_ids):
            raise ProtocolError("INVALID_REQUEST", "candidate_ids 必须是非空字符串列表")
        player_id = payload.get("player_id")
        if player_id is not None and (not isinstance(player_id, str) or not player_id):
            raise ProtocolError("INVALID_REQUEST", "player_id 必须是字符串或 null")
        try:
            count = self._require_store(payload).set_candidates_player(candidate_ids, player_id)
        except (ValueError, LookupError) as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"updated": count}

    def start_review(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        try:
            started_at = self._require_store(payload).start_review(
                payload["candidate_id"],
                payload.get("review_started_at"),
            )
        except KeyError as exc:
            raise ProtocolError("INVALID_REQUEST", f"缺少字段: {exc.args[0]}") from exc
        except (ValueError, LookupError) as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"review_started_at": started_at}

    def review_candidate(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        try:
            self._require_store(payload).review_candidate(
                payload["candidate_id"],
                payload["status"],
                payload.get("note"),
                payload.get("reason"),
                payload.get("review_started_at"),
            )
        except KeyError as exc:
            raise ProtocolError("INVALID_REQUEST", f"缺少字段: {exc.args[0]}") from exc
        except (ValueError, LookupError) as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"updated": True}

    def list_review_history(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        try:
            history = self._require_store(payload).list_review_history(payload["candidate_id"])
        except KeyError as exc:
            raise ProtocolError("INVALID_REQUEST", f"缺少字段: {exc.args[0]}") from exc
        return {"history": history}

    def update_clip_range(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        try:
            self._require_store(payload).update_clip_range(payload["candidate_id"], int(payload["start_ms"]), int(payload["end_ms"]))
        except KeyError as exc:
            raise ProtocolError("INVALID_REQUEST", f"缺少字段: {exc.args[0]}") from exc
        except (ValueError, LookupError) as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"updated": True}

    def _execute_export(
        self,
        payload: Dict[str, Any],
        progress_callback=None,
        cancel_check=None,
        process_callback=None,
    ) -> Dict[str, Any]:
        store = self._require_store(payload)
        project = store.project()
        video_id = payload.get("video_id")
        video = store.video(video_id) if isinstance(video_id, str) else None
        if not project or not video:
            raise ProtocolError("VIDEO_NOT_FOUND", "导出任务缺少有效视频")
        source = self._validated_source(video)
        self._ensure_disk_space(store.root, source)
        raw_snapshot = payload.get("candidate_snapshot")
        if not isinstance(raw_snapshot, list):
            raise ProtocolError("EXPORT_SNAPSHOT_MISSING", "导出任务缺少候选快照")
        candidates = [
            dict(candidate)
            for candidate in raw_snapshot
            if isinstance(candidate, dict)
        ]
        if not candidates:
            raise ProtocolError("NO_EXPORT_CANDIDATES", "没有可导出的候选片段")
        mode = payload.get("mode", "separate")
        raw_output = payload.get("output_dir")
        output_dir = Path(raw_output).expanduser() if isinstance(raw_output, str) and raw_output.strip() else (
            store.root / "artifacts" / "exports" / f"export_{int(time.time())}"
        )
        if not output_dir.is_absolute():
            output_dir = store.root / output_dir
        output_dir = output_dir.resolve()
        output_path = payload.get("output_path")
        merged_output = None
        if isinstance(output_path, str) and output_path.strip():
            merged_output = Path(output_path).expanduser()
            if not merged_output.is_absolute():
                merged_output = store.root / merged_output
            merged_output = merged_output.resolve()
        if merged_output is not None and merged_output == source.resolve():
            raise ProtocolError(
                "EXPORT_SOURCE_CONFLICT",
                "导出目标不能覆盖原始视频",
                {"source_path": str(source.resolve())},
            )
        try:
            result = export_goal_clips(
                source,
                candidates,
                output_dir,
                mode,
                merged_output,
                progress_callback=progress_callback,
                cancel_check=cancel_check,
                process_callback=process_callback,
            )
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            raise ProtocolError("EXPORT_FAILED", f"导出失败: {exc}") from exc
        if cancel_check and cancel_check():
            for path in {
                *result.get("files", []),
                *result.get("clip_files", []),
            }:
                Path(path).unlink(missing_ok=True)
            raise PipelineCancelled("JOB_CANCELLED")
        try:
            self._validated_source(video)
        except ProtocolError:
            for path in {
                *result.get("files", []),
                *result.get("clip_files", []),
            }:
                Path(path).unlink(missing_ok=True)
            raise
        file_size = sum(Path(path).stat().st_size for path in result["files"] if Path(path).is_file())
        export_path = result["files"][0] if len(result["files"]) == 1 else str(output_dir)
        exported_info: Dict[str, Any] = {}
        if result["files"]:
            try:
                exported_info = self.inspect_video({"video_path": result["files"][0]})
            except ProtocolError:
                exported_info = {}
        export = store.create_export({
            "project_id": project["id"],
            "video_id": video_id,
            "output_path": export_path,
            "mode": mode,
            "candidate_count": len(candidates),
            "duration_ms": result["duration_ms"],
            "file_size_bytes": file_size,
            "width": exported_info.get("width"),
            "height": exported_info.get("height"),
            "video_codec": exported_info.get("video_codec"),
            "audio_codec": exported_info.get("audio_codec"),
            "processing_ms": result["processing_ms"],
            "export_ms": result["processing_ms"],
            "algorithm_version": ANALYSIS_ALGORITHM_VERSION,
            "metadata": {"files": result["files"], "clip_files": result["clip_files"]},
        })
        return {"export": export, "files": result["files"]}

    def start_export(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store = self._require_store(payload)
        project = store.project()
        video_id = payload.get("video_id")
        video = store.video(video_id) if isinstance(video_id, str) else None
        if not project or not video:
            raise ProtocolError("VIDEO_NOT_FOUND", "导出任务缺少有效视频")
        source = self._validated_source(video)
        self._ensure_disk_space(store.root, source)
        with self._job_lock:
            self._job_threads = {
                job_id: thread
                for job_id, thread in self._job_threads.items()
                if thread.is_alive()
            }
            if self._job_threads:
                raise ProtocolError("JOB_ALREADY_RUNNING", "已有重型任务正在运行")
            active = self._unfinished_heavy_jobs(store, project["id"])
            if active:
                raise ProtocolError(
                    "JOB_RECOVERY_REQUIRED",
                    "项目存在未完成的分析或导出任务，请先恢复、重试或取消该任务",
                    {"job_ids": [item["id"] for item in active]},
                )
            requested_player_ids = payload.get("player_ids")
            if requested_player_ids is not None and (
                not isinstance(requested_player_ids, list)
                or not all(isinstance(item, str) and item for item in requested_player_ids)
            ):
                raise ProtocolError("INVALID_REQUEST", "player_ids 必须是字符串列表")
            include_unassigned = payload.get("include_unassigned", True) is True
            selected_players = {item for item in requested_player_ids or []}
            candidate_snapshot = [
                {
                    "id": candidate["id"],
                    "event_time_ms": int(candidate["event_time_ms"]),
                    "review_start_ms": int(candidate["review_start_ms"]),
                    "review_end_ms": int(candidate["review_end_ms"]),
                }
                for candidate in store.list_candidates(video_id)
                if candidate.get("selection_status") != "excluded"
                and (
                    requested_player_ids is None
                    or candidate.get("player_id") in selected_players
                    or (include_unassigned and not candidate.get("player_id"))
                )
            ]
            if not candidate_snapshot:
                raise ProtocolError("NO_EXPORT_CANDIDATES", "没有可导出的候选片段")
            checkpoint = {
                "mode": payload.get("mode", "separate"),
                "output_dir": payload.get("output_dir"),
                "output_path": payload.get("output_path"),
                "player_ids": sorted(selected_players) if requested_player_ids is not None else None,
                "include_unassigned": include_unassigned,
                "candidate_snapshot": candidate_snapshot,
                "candidate_count": len(candidate_snapshot),
            }
            job = store.create_job(project["id"], video_id, "export", checkpoint)
            job_id = job["id"]
            worker_payload = {
                **payload,
                "candidate_snapshot": candidate_snapshot,
            }
            thread = threading.Thread(
                target=self._run_export,
                args=(worker_payload, job_id),
                name=f"export-{job_id}",
                daemon=True,
            )
            self._job_threads[job_id] = thread
            self._job_cancel_events[job_id] = threading.Event()
            try:
                thread.start()
            except RuntimeError as exc:
                self._job_threads.pop(job_id, None)
                self._job_cancel_events.pop(job_id, None)
                store.update_job(
                    job_id,
                    state="failed",
                    stage="export",
                    error_code="EXPORT_FAILED",
                    error_message=str(exc),
                )
                raise ProtocolError("EXPORT_FAILED", "无法启动导出任务") from exc
        return {"job": job}

    def _run_export(self, payload: Dict[str, Any], job_id: str) -> None:
        store = self._require_store(payload)
        cancel_event = self._job_cancel_events.get(job_id)
        initial_job = store.get_job(job_id) or {}
        initial_checkpoint = self._decode_checkpoint(initial_job)

        def on_progress(stage: str, progress: float) -> None:
            if cancel_event and cancel_event.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            store.update_job(
                job_id,
                state="running",
                stage=stage,
                progress=max(0.01, min(0.99, float(progress))),
            )

        try:
            store.update_job(job_id, state="running", stage="export_clips", progress=0.01)
            result = self._execute_export(
                payload,
                progress_callback=on_progress,
                cancel_check=cancel_event.is_set if cancel_event else None,
                process_callback=lambda process: self._set_job_process(job_id, process),
            )
            if cancel_event and cancel_event.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            store.update_job(
                job_id,
                state="completed",
                stage="persist_export",
                progress=1.0,
                checkpoint={
                    **initial_checkpoint,
                    "export": result.get("export"),
                    "files": result.get("files", []),
                },
            )
        except PipelineCancelled:
            store.update_job(
                job_id,
                state="cancelled",
                stage="export",
                error_code="JOB_CANCELLED",
                error_message="任务已取消",
            )
        except ProtocolError as exc:
            store.update_job(
                job_id,
                state="failed",
                stage="export",
                error_code=exc.code,
                error_message=exc.message,
            )
        except Exception as exc:
            store.update_job(
                job_id,
                state="failed",
                stage="export",
                error_code="EXPORT_FAILED",
                error_message=str(exc),
            )
        finally:
            with self._job_lock:
                self._job_threads.pop(job_id, None)
                self._job_cancel_events.pop(job_id, None)

    def get_statistics(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        return {"statistics": self._require_store(payload).statistics()}

    def list_exports(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store = self._require_store(payload)
        project = store.project()
        if not project:
            raise ProtocolError("PROJECT_INVALID", "项目尚未初始化")
        try:
            limit = int(payload.get("limit", 20))
        except (TypeError, ValueError) as exc:
            raise ProtocolError("INVALID_REQUEST", "limit 必须是整数") from exc
        try:
            exports = store.list_exports(project["id"], limit)
        except ValueError as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"exports": exports}

    def set_telemetry_consent(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        try:
            self._require_store(payload).set_telemetry_consent(payload["status"])
        except KeyError as exc:
            raise ProtocolError("INVALID_REQUEST", f"缺少字段: {exc.args[0]}") from exc
        except ValueError as exc:
            raise ProtocolError("INVALID_REQUEST", str(exc)) from exc
        return {"updated": True}

    def cleanup_artifacts(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        store = self._require_store(payload)
        project = store.project()
        if not project:
            raise ProtocolError("PROJECT_INVALID", "项目尚未初始化")
        with self._job_lock:
            active_jobs = store.list_jobs(
                project_id=project["id"],
                states=("queued", "running"),
            )
            if active_jobs:
                raise ProtocolError(
                    "PROJECT_BUSY",
                    "项目仍有任务运行，请先取消任务后再清理缓存",
                    {"job_ids": [job["id"] for job in active_jobs]},
                )
        return store.cleanup_artifacts(bool(payload.get("include_exports", False)))
