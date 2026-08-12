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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict

from . import __version__
from .adapters.analysis import (
    build_pipeline_commands,
    candidate_to_row,
    flatten_refined_matches,
    PipelineCancelled,
    run_pipeline,
    scale_roi_to_proxy,
    terminate_process,
)
from .adapters.export import export_goal_clips
from .protocol import ProtocolError
from .storage import ProjectStore, new_id


ANALYSIS_ALGORITHM_VERSION = "python-v2.10-white-net-trajectory"


class EngineService:
    _MIN_WORKING_SPACE_BYTES = 512 * 1024 * 1024

    def __init__(self) -> None:
        self.stores: dict[str, ProjectStore] = {}
        self._job_threads: dict[str, threading.Thread] = {}
        self._job_cancel_events: dict[str, threading.Event] = {}
        self._job_processes: dict[str, subprocess.Popen] = {}
        self._store_lock = threading.Lock()
        self._job_lock = threading.Lock()

    def shutdown(self, timeout: float = 5.0) -> None:
        with self._job_lock:
            thread_items = list(self._job_threads.items())
            cancel_events = list(self._job_cancel_events.values())
            processes = list(self._job_processes.values())
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
            "retry_analysis": self.retry_analysis,
            "retry_export": self.retry_export,
            "list_candidates": self.list_candidates,
            "list_players": self.list_players,
            "create_player": self.create_player,
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
        streams = probe.get("streams", [])
        video_stream = next((item for item in streams if item.get("codec_type") == "video"), None)
        audio_stream = next((item for item in streams if item.get("codec_type") == "audio"), None)
        if not video_stream:
            raise ProtocolError("VIDEO_FORMAT_UNSUPPORTED", "文件中没有视频流")
        fps = self._parse_ratio(video_stream.get("r_frame_rate"))
        duration_ms = round(float(probe.get("format", {}).get("duration", 0)) * 1000)
        disk = shutil.disk_usage(path.parent)
        estimated_working_space = max(
            self._MIN_WORKING_SPACE_BYTES,
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
            "width": video_stream.get("width"),
            "height": video_stream.get("height"),
            "fps": fps,
            "video_codec": video_stream.get("codec_name"),
            "audio_codec": audio_stream.get("codec_name") if audio_stream else None,
            "available_disk_bytes": disk.free,
            "estimated_working_space_bytes": estimated_working_space,
            "disk_space_sufficient": disk.free >= estimated_working_space,
        }

    def _ensure_disk_space(self, workspace: Path, source: Path) -> None:
        if not source.is_file():
            return
        disk = shutil.disk_usage(workspace)
        required = max(
            self._MIN_WORKING_SPACE_BYTES,
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

    @staticmethod
    def _validated_source(video: Dict[str, Any]) -> Path:
        source = Path(video["source_path"])
        if not source.is_file():
            raise ProtocolError("VIDEO_NOT_FOUND", f"原始视频不存在: {source}")
        stat = source.stat()
        stored_size = video.get("source_size_bytes")
        stored_mtime = video.get("source_mtime_ns")
        if (
            stored_size is not None
            and stored_mtime is not None
            and (
                int(stored_size) != stat.st_size
                or int(stored_mtime) != stat.st_mtime_ns
            )
        ):
            raise ProtocolError(
                "VIDEO_SOURCE_CHANGED",
                "原视频内容已变化，请重新导入视频并校准篮筐区域",
            )
        return source

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
            or (repo_root / "third_party" / "basketball-shot-detection" / "bball_model.pt")
        ).expanduser().resolve()
        if not model_path.is_file():
            raise ProtocolError("MODEL_LOAD_FAILED", f"模型不存在: {model_path}")

        try:
            sample_fps = float(payload.get("sample_fps", 1.0))
            duration = float(payload.get("duration", 20.0))
            max_samples = int(payload.get("max_samples", 12))
            confidence = float(payload.get("confidence", 0.05))
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
        return {
            "roi": roi,
            "calibration": calibration,
            "suggestion": result,
        }

    @staticmethod
    def _parse_ratio(value: Any) -> float | None:
        if not isinstance(value, str) or "/" not in value:
            return None
        numerator, denominator = value.split("/", 1)
        try:
            return float(numerator) / float(denominator)
        except (ValueError, ZeroDivisionError):
            return None

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
        source = self._latest_proxy_video(store, video_id) or self._validated_source(video)
        try:
            time_ms = max(0, min(int(payload.get("time_ms", 1000)), int(video.get("duration_ms") or 1000)))
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

    def _latest_proxy_video(self, store: ProjectStore, video_id: str) -> Path | None:
        project = store.project()
        if not project:
            return None
        jobs = store.list_jobs(
            project_id=project["id"],
            job_type="analysis",
            states=("completed",),
            video_id=video_id,
        )
        for job in reversed(jobs):
            candidate = self._decode_checkpoint(job).get("proxy_video")
            if not isinstance(candidate, str) or not candidate:
                continue
            path = Path(candidate).expanduser()
            if path.is_file() and path.stat().st_size > 0:
                return path.resolve()
        return None

    @staticmethod
    def _preview_path(
        store: ProjectStore,
        video: Dict[str, Any],
        time_ms: int,
    ) -> Path:
        fingerprint = hashlib.sha256(
            f"{video.get('source_size_bytes')}:{video.get('source_mtime_ns')}".encode("utf-8")
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
        for index, row in enumerate(rows):
            if cancel_event and cancel_event.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            time_ms = max(0, int(row["event_time_ms"]))
            output_path = self._preview_path(store, video, time_ms)
            if output_path.is_file() and output_path.stat().st_size > 0:
                reused += 1
            else:
                temporary_path = output_path.with_name(
                    f".{output_path.stem}.{job_id}.tmp{output_path.suffix}"
                )
                command = [
                    "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                    "-ss", f"{time_ms / 1000:.3f}", "-i", str(source),
                    "-frames:v", "1", "-vf", "scale=640:-2", "-q:v", "3",
                    str(temporary_path),
                ]
                popen_kwargs: Dict[str, Any] = {
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
                        generated += 1
                    else:
                        temporary_path.unlink(missing_ok=True)
                        failed += 1
                        if stderr:
                            print(
                                f"candidate preview failed at {time_ms}ms: {stderr[-500:]}",
                                file=sys.stderr,
                            )
                finally:
                    temporary_path.unlink(missing_ok=True)
                    self._set_job_process(job_id, None)
            store.update_job(
                job_id,
                state="running",
                stage="prepare_review_previews",
                progress=0.96 + 0.035 * ((index + 1) / total),
            )
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
        video = store.video(video_id)
        if video:
            self._ensure_disk_space(store.root, Path(video["source_path"]))
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
            "sample_fps": sample_fps,
            "window_seconds": window_seconds,
            "before_seconds": before_seconds,
            "after_seconds": after_seconds,
            "analysis_start_ms": analysis_start_ms,
            "analysis_end_ms": analysis_end_ms,
            "algorithm_version": ANALYSIS_ALGORITHM_VERSION,
        }
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
            )
        retry_payload = dict(payload)
        retry_payload.pop("job_id", None)
        for key in (
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
            )
        checkpoint = self._decode_checkpoint(job)
        retry_payload = {
            "project_root": str(store.root),
            "video_id": job.get("video_id"),
            "mode": checkpoint.get("mode", "separate"),
        }
        if checkpoint.get("output_dir") is not None:
            retry_payload["output_dir"] = checkpoint["output_dir"]
        if checkpoint.get("output_path") is not None:
            retry_payload["output_path"] = checkpoint["output_path"]
        return self.start_export(retry_payload)

    def _run_analysis(self, payload: Dict[str, Any], job_id: str) -> None:
        store = self._require_store(payload)
        try:
            video_id = payload["video_id"]
            video = store.video(video_id)
            roi = store.active_roi(video_id)
            if not video or not roi:
                raise ProtocolError("VIDEO_NOT_FOUND", "分析任务数据已失效")
            source_video = self._validated_source(video)
            repo_root = Path(__file__).resolve().parents[3]
            model_path = Path(payload.get("model_path") or (repo_root / "third_party" / "basketball-shot-detection" / "bball_model.pt")).expanduser().resolve()
            if not model_path.is_file():
                raise ProtocolError("MODEL_LOAD_FAILED", f"模型不存在: {model_path}")
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
            )

            checkpoint = {
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
                refined_output,
                on_stage,
                cancel_check=cancel_event.is_set if cancel_event else None,
                process_callback=lambda process: self._set_job_process(job_id, process),
                manifest_path=manifest_path,
                stage_outputs=[proxy_video, coarse_detections, coarse_candidates, refined_output],
                manifest_version=ANALYSIS_ALGORITHM_VERSION,
            )
            if cancel_event and cancel_event.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            matches = flatten_refined_matches(pipeline["refined"])
            detection_counts = self._detection_counts(coarse_detections)
            rows = [
                candidate_to_row(
                    match,
                    video_id=video_id,
                    roi_id=roi["id"],
                    duration_ms=int(video.get("duration_ms") or 0),
                    before_seconds=float(payload.get("before_seconds", 6)),
                    after_seconds=float(payload.get("after_seconds", 3)),
                    detector_version=ANALYSIS_ALGORITHM_VERSION,
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
            preview_counts = self._prepare_candidate_previews(
                store=store,
                source=proxy_video,
                video=video,
                video_id=video_id,
                rows=eager_preview_rows,
                job_id=job_id,
                cancel_event=cancel_event,
            )
            preview_counts["deferred"] = len(rows) - len(eager_preview_rows)
            if cancel_event and cancel_event.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            store.replace_candidates(video_id, rows)
            checkpoint = {
                **checkpoint,
                "candidate_count": len(rows),
                "detection_counts": detection_counts,
                "preview_counts": preview_counts,
                "logs": pipeline["logs"],
                "cache_hits": pipeline.get("cache_hits", 0),
            }
            store.update_job(job_id, state="completed", stage="persist_candidates", progress=1.0, checkpoint=checkpoint)
        except PipelineCancelled:
            store.update_job(
                job_id,
                state="cancelled",
                stage="analysis",
                error_code="JOB_CANCELLED",
                error_message="任务已取消",
            )
        except ProtocolError as exc:
            store.update_job(job_id, state="failed", stage="analysis", error_code=exc.code, error_message=exc.message)
        except Exception as exc:
            store.update_job(job_id, state="failed", stage="analysis", error_code="ANALYSIS_FAILED", error_message=str(exc))
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
                self._job_processes[job_id] = process

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
            process = self._job_processes.get(job_id)
            if cancel_event:
                cancel_event.set()
            should_persist = not cancel_event and not process
        # Do not hold _job_lock while waiting for the process group. The
        # worker needs the same lock to clear its process handle in finally.
        if process:
            terminate_process(process)
        if cancel_event or process:
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
        review_video_path = None
        if context.get("project") and isinstance(video_id, str) and video_id:
            proxy = self._latest_proxy_video(store, video_id)
            if proxy is not None:
                review_video_path = str(proxy)
        return {
            "candidates": candidates,
            "review_video_path": review_video_path,
            "players": store.list_players(),
        }

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
                checkpoint={"export": result.get("export"), "files": result.get("files", [])},
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
