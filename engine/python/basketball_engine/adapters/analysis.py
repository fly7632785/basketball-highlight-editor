from __future__ import annotations

import sys
import json
import os
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable
from uuid import uuid5, NAMESPACE_URL

# The desktop runtime puts the engine and the shared analysis package in
# sibling directories under the bundled runtime root.
_RUNTIME_ROOT = Path(__file__).resolve().parents[4]
_SRC_PATH = _RUNTIME_ROOT / "src"
if _SRC_PATH.is_dir() and str(_SRC_PATH) not in sys.path:
    sys.path.insert(0, str(_SRC_PATH))

from basketball_highlight.review_reason import suggest_review_reasons
from basketball_highlight.ranking import dedupe_candidates


class PipelineCancelled(Exception):
    pass


def terminate_process(process: subprocess.Popen) -> None:
    """Stop a pipeline step and its child process group."""
    if process.poll() is not None:
        return
    try:
        if os.name == "nt":
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                check=False,
                capture_output=True,
            )
        else:
            os.killpg(process.pid, 15)
    except (OSError, ProcessLookupError):
        try:
            process.terminate()
        except OSError:
            return
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    check=False,
                    capture_output=True,
                )
            else:
                os.killpg(process.pid, 9)
        except (OSError, ProcessLookupError):
            process.kill()
        process.wait(timeout=2)


def scale_roi_to_proxy(
    roi: Dict[str, Any],
    source_width: int,
    proxy_width: int,
    *,
    source_height: int | None = None,
    proxy_height: int | None = None,
) -> list[int]:
    if source_width <= 0 or proxy_width <= 0:
        raise ValueError("VIDEO_DIMENSION_INVALID")
    if (source_height is None) != (proxy_height is None):
        raise ValueError("VIDEO_DIMENSION_INVALID")
    if source_height is not None and proxy_height is not None:
        if source_height <= 0 or proxy_height <= 0:
            raise ValueError("VIDEO_DIMENSION_INVALID")
        ratio = min(proxy_width / source_width, proxy_height / source_height)
    else:
        ratio = proxy_width / source_width
    return [
        round(float(roi[key]) * ratio)
        for key in ("x1", "y1", "x2", "y2")
    ]


def flatten_refined_matches(data: Dict[str, Any], dedupe_seconds: float = 1.0) -> list[Dict[str, Any]]:
    matches = [
        dict(match)
        for result in data.get("results", [])
        for match in result.get("refined", [])
        if (
            isinstance(match, dict)
            and "time" in match
            and match.get("verdict") != "missed"
        )
    ]
    return dedupe_candidates(matches, dedupe_seconds)


def candidate_to_row(
    match: Dict[str, Any],
    video_id: str,
    roi_id: str,
    duration_ms: int,
    before_seconds: float,
    after_seconds: float,
    detector_version: str,
) -> Dict[str, Any]:
    event_time_ms = round(float(match["time"]) * 1000)
    start_ms = max(0, event_time_ms - round(before_seconds * 1000))
    end_ms = min(duration_ms, event_time_ms + round(after_seconds * 1000))
    timestamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
    evidence = dict(match)
    evidence["review_reason_suggestion"] = suggest_review_reasons(match)
    return {
        "id": f"candidate_{uuid5(NAMESPACE_URL, f'{video_id}:{roi_id}:{detector_version}:{event_time_ms}').hex}",
        "video_id": video_id,
        "roi_id": roi_id,
        "group_id": None,
        "event_time_ms": event_time_ms,
        "default_start_ms": start_ms,
        "default_end_ms": end_ms,
        "review_start_ms": start_ms,
        "review_end_ms": end_ms,
        "detector_version": detector_version,
        "score": match.get("score"),
        "confidence": match.get("confidence", "pending"),
        "evidence_json": json.dumps(evidence, ensure_ascii=False),
        "created_at": timestamp,
        "updated_at": timestamp,
    }


def _script(repo_root: Path, name: str) -> str:
    return str((repo_root / "scripts" / name).resolve())


def build_pipeline_commands(
    repo_root: Path,
    source_video: Path,
    proxy_video: Path,
    model_path: Path,
    coarse_detections: Path,
    coarse_candidates: Path,
    refined_output: Path,
    proxy_roi: Iterable[int],
    source_roi: Iterable[int],
    cache_dir: Path,
    proxy_width: int = 960,
    proxy_height: int = 720,
    proxy_fps: float = 5.0,
    proxy_scale: float = 1.0,
    coarse_scale: int = 4,
    refine_sample_fps: float = 10.0,
    refine_scale: int = 2,
    batch: int = 8,
    conf: float = 0.10,
    window_seconds: float = 2.5,
) -> list[list[str]]:
    proxy_roi_args = [str(round(float(value))) for value in proxy_roi]
    source_roi_args = [str(round(float(value))) for value in source_roi]
    return [
        [
            sys.executable, _script(repo_root, "create_proxy.py"),
            "--video", str(source_video), "--output", str(proxy_video),
            "--width", str(proxy_width), "--height", str(proxy_height),
            "--fps", str(proxy_fps),
        ],
        [
            sys.executable, _script(repo_root, "scan_video.py"),
            "--video", str(proxy_video), "--model", str(model_path),
            "--roi", *proxy_roi_args, "--sample-fps", str(proxy_fps),
            "--scale", str(coarse_scale), "--batch", str(batch),
            "--conf", str(conf), "--cache-dir", str(cache_dir / "coarse"),
            "--output", str(coarse_detections),
        ],
        [
            sys.executable, _script(repo_root, "generate_candidates.py"),
            "--detections", str(coarse_detections), "--output", str(coarse_candidates),
        ],
        [
            sys.executable, _script(repo_root, "refine_dynamic_candidates.py"),
            "--video", str(source_video), "--model", str(model_path),
            "--coarse", str(coarse_candidates), "--roi", *source_roi_args,
            "--proxy-scale", str(proxy_scale), "--sample-fps", str(refine_sample_fps),
            "--window", str(window_seconds),
            "--scale", str(refine_scale), "--conf", str(conf),
            "--batch", str(batch), "--cache-dir", str(cache_dir / "refine"),
            "--output", str(refined_output),
        ],
    ]


def run_pipeline(
    commands: list[list[str]],
    refined_output: Path,
    stage_callback=None,
    output_callback=None,
    cancel_check=None,
    process_callback=None,
    manifest_path: Path | None = None,
    stage_outputs: Iterable[Path | None] | None = None,
    manifest_version: str | int = 1,
) -> Dict[str, Any]:
    stages = ("prepare_proxy", "coarse_scan", "generate_candidates", "refine_candidates")
    if len(commands) == 4:
        stage_ranges = (
            (0.01, 0.14),
            (0.14, 0.44),
            (0.44, 0.46),
            (0.46, 0.95),
        )
    else:
        stage_width = 0.94 / max(1, len(commands))
        stage_ranges = tuple(
            (0.01 + index * stage_width, 0.01 + (index + 1) * stage_width)
            for index in range(len(commands))
        )
    logs: list[str] = []
    cache_hits = 0
    outputs = list(stage_outputs or [None] * len(commands))
    if len(outputs) != len(commands):
        raise ValueError("PIPELINE_STAGE_OUTPUTS_INVALID")

    manifest: Dict[str, Any] = {"version": manifest_version, "stages": {}}
    if manifest_path and manifest_path.is_file():
        try:
            loaded = json.loads(manifest_path.read_text(encoding="utf-8"))
            if (
                isinstance(loaded, dict)
                and loaded.get("version") == manifest_version
                and isinstance(loaded.get("stages"), dict)
            ):
                manifest.update(loaded)
        except (OSError, json.JSONDecodeError):
            # A truncated manifest must not make an otherwise recoverable run
            # fail. The next completed stage will replace it atomically.
            pass

    def save_manifest() -> None:
        if not manifest_path:
            return
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = manifest_path.with_name(f".{manifest_path.name}.tmp")
        temporary.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        temporary.replace(manifest_path)

    def artifact_valid(path: Path | None) -> bool:
        if path is None:
            return True
        if not path.is_file() or path.stat().st_size <= 0:
            return False
        if path.suffix.lower() != ".json":
            return True
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return False
        return True

    for index, command in enumerate(commands):
        if cancel_check and cancel_check():
            raise PipelineCancelled("JOB_CANCELLED")
        stage = stages[index] if index < len(stages) else f"stage_{index + 1}"
        output = outputs[index]
        previous = manifest.get("stages", {}).get(stage, {})
        if (
            isinstance(previous, dict)
            and previous.get("state") == "completed"
            and artifact_valid(output)
        ):
            cache_hits += 1
            logs.append(f"{stage}: reused {output}")
            if stage_callback:
                stage_callback(stage, stage_ranges[index][1])
            continue
        if stage_callback:
            stage_callback(stage, stage_ranges[index][0])
        manifest.setdefault("stages", {})[stage] = {
            "state": "running",
            "started_at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "output": str(output) if output else None,
        }
        save_manifest()
        popen_kwargs = {
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "text": True,
        }
        if os.name == "nt":
            popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            popen_kwargs["start_new_session"] = True
        process = subprocess.Popen(command, **popen_kwargs)
        if process_callback:
            process_callback(process)
        try:
            stdout_lines: list[str] = []
            stderr_lines: list[str] = []

            def read_stream(stream, lines: list[str]) -> None:
                for line in iter(stream.readline, ""):
                    lines.append(line)
                    stripped = line.strip()
                    if stripped.startswith("progress=") and stage_callback:
                        try:
                            local_progress = float(stripped.split("=", 1)[1])
                        except ValueError:
                            local_progress = None
                        if local_progress is not None:
                            start_progress, end_progress = stage_ranges[index]
                            global_progress = start_progress + (
                                end_progress - start_progress
                            ) * max(0.0, min(1.0, local_progress))
                            stage_callback(stage, max(0.01, global_progress))
                    if output_callback:
                        output_callback(stage, stripped)
                stream.close()

            stdout_reader = threading.Thread(
                target=read_stream,
                args=(process.stdout, stdout_lines),
                name=f"pipeline-stdout-{index}",
                daemon=True,
            )
            stderr_reader = threading.Thread(
                target=read_stream,
                args=(process.stderr, stderr_lines),
                name=f"pipeline-stderr-{index}",
                daemon=True,
            )
            stdout_reader.start()
            stderr_reader.start()
            while process.poll() is None:
                if cancel_check and cancel_check():
                    terminate_process(process)
                    stdout_reader.join(timeout=3)
                    stderr_reader.join(timeout=3)
                    raise PipelineCancelled("JOB_CANCELLED")
                time.sleep(0.05)
            process.wait()
            stdout_reader.join(timeout=3)
            stderr_reader.join(timeout=3)
            stdout = "".join(stdout_lines)
            stderr = "".join(stderr_lines)
            if cancel_check and cancel_check():
                raise PipelineCancelled("JOB_CANCELLED")
            if process.returncode != 0:
                details = (stderr or stdout or "").strip()
                if len(details) > 1200:
                    details = details[-1200:]
                script_name = (
                    Path(command[1]).name
                    if len(command) > 1 and command[1].endswith(".py")
                    else "pipeline step"
                )
                message = f"{script_name} 执行失败"
                if details:
                    message = f"{message}: {details}"
                raise RuntimeError(message)
            completed_stdout = stdout or ""
            completed_stderr = stderr or ""
            if not artifact_valid(output):
                raise RuntimeError(f"{stage} 未生成有效产物")
            manifest.setdefault("stages", {})[stage] = {
                "state": "completed",
                "finished_at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                "output": str(output) if output else None,
            }
            save_manifest()
        except PipelineCancelled:
            manifest.setdefault("stages", {})[stage] = {
                "state": "cancelled",
                "finished_at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                "output": str(output) if output else None,
            }
            save_manifest()
            raise
        except Exception as exc:
            manifest.setdefault("stages", {})[stage] = {
                "state": "failed",
                "finished_at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                "output": str(output) if output else None,
                "error": str(exc),
            }
            save_manifest()
            raise
        finally:
            if process_callback:
                process_callback(None)
        if completed_stdout:
            logs.append(completed_stdout[-4000:])
        if completed_stderr:
            logs.append(completed_stderr[-4000:])
    if cancel_check and cancel_check():
        raise PipelineCancelled("JOB_CANCELLED")
    if stage_callback:
        stage_callback("persist_candidates", 0.95)
    return {
        "refined": json.loads(refined_output.read_text(encoding="utf-8")),
        "logs": logs,
        "manifest": manifest,
        "cache_hits": cache_hits,
    }
