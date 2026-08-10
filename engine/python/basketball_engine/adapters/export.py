from __future__ import annotations

import platform
import subprocess
import time
from pathlib import Path
from typing import Any, Dict
from uuid import uuid4

from .analysis import PipelineCancelled, terminate_process


def preferred_video_codec() -> str:
    return "h264_videotoolbox" if platform.system() == "Darwin" else "libx264"


def concat_manifest_entry(path: Path) -> str:
    """Render a path safely for the ffmpeg concat demuxer on macOS and Windows."""
    normalized = path.resolve().as_posix().replace("'", "'\\''")
    return f"file '{normalized}'\n"


def available_output_path(path: Path) -> Path:
    if not path.exists():
        return path
    for index in range(2, 10_000):
        candidate = path.with_name(f"{path.stem}_{index}{path.suffix}")
        if not candidate.exists():
            return candidate
    raise OSError(f"无法生成不冲突的导出文件名: {path}")


def build_clip_command(
    source_video: Path,
    start_ms: int,
    end_ms: int,
    output_path: Path,
    video_codec: str | None = None,
) -> list[str]:
    if start_ms < 0 or end_ms <= start_ms:
        raise ValueError("INVALID_CLIP_RANGE")
    duration = (end_ms - start_ms) / 1000
    codec = video_codec or preferred_video_codec()
    codec_options = ["-c:v", codec]
    if codec == "libx264":
        codec_options = ["-c:v", codec, "-preset", "veryfast", "-crf", "22"]
    command = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-ss", f"{start_ms / 1000:.3f}", "-i", str(source_video),
        "-t", f"{duration:.3f}",
        "-map", "0:v:0?", "-map", "0:a?",
        *codec_options, "-c:a", "aac", "-b:a", "128k",
        "-movflags", "+faststart", str(output_path),
    ]
    return command


def validate_media_file(path: Path) -> None:
    if not path.is_file() or path.stat().st_size <= 0:
        raise OSError(f"导出文件为空: {path}")
    result = subprocess.run(
        [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
    )
    try:
        duration = float(result.stdout.strip())
    except ValueError as exc:
        raise OSError(f"导出文件时长无效: {path}") from exc
    if duration <= 0:
        raise OSError(f"导出文件时长为零: {path}")


def run_atomic_ffmpeg(
    command: list[str],
    output_path: Path,
    cancel_check=None,
    process_callback=None,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(
        f".{output_path.stem}.{uuid4().hex}.part{output_path.suffix}"
    )
    atomic_command = [*command[:-1], str(temporary)]
    try:
        popen_kwargs = {}
        if platform.system() == "Windows":
            popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            popen_kwargs["start_new_session"] = True
        process = subprocess.Popen(atomic_command, **popen_kwargs)
        if process_callback:
            process_callback(process)
        try:
            while process.poll() is None:
                if cancel_check and cancel_check():
                    terminate_process(process)
                    raise PipelineCancelled("JOB_CANCELLED")
                time.sleep(0.05)
            if cancel_check and cancel_check():
                raise PipelineCancelled("JOB_CANCELLED")
            if process.returncode != 0:
                raise subprocess.CalledProcessError(process.returncode, atomic_command)
        finally:
            if process_callback:
                process_callback(None)
        validate_media_file(temporary)
        temporary.replace(output_path)
    finally:
        temporary.unlink(missing_ok=True)


def export_goal_clips(
    source_video: Path,
    candidates: list[Dict[str, Any]],
    output_dir: Path,
    mode: str,
    output_path: Path | None = None,
    progress_callback=None,
    cancel_check=None,
    process_callback=None,
) -> Dict[str, Any]:
    if mode not in {"separate", "merge"}:
        raise ValueError("INVALID_EXPORT_MODE")
    started = time.perf_counter()
    output_dir.mkdir(parents=True, exist_ok=True)
    files: list[Path] = []
    created_files: list[Path] = []
    try:
        for index, candidate in enumerate(candidates, 1):
            path = available_output_path(
                output_dir / f"goal_{index:03d}_{candidate['event_time_ms'] / 1000:.2f}s.mp4"
            )
            codec = preferred_video_codec()
            try:
                run_atomic_ffmpeg(
                    build_clip_command(
                        source_video,
                        int(candidate["review_start_ms"]),
                        int(candidate["review_end_ms"]),
                        path,
                        codec,
                    ),
                    path,
                    cancel_check=cancel_check,
                    process_callback=process_callback,
                )
            except subprocess.CalledProcessError:
                if codec == "libx264":
                    raise
                run_atomic_ffmpeg(
                    build_clip_command(
                        source_video,
                        int(candidate["review_start_ms"]),
                        int(candidate["review_end_ms"]),
                        path,
                        "libx264",
                    ),
                    path,
                    cancel_check=cancel_check,
                    process_callback=process_callback,
                )
            created_files.append(path)
            files.append(path)
            if progress_callback:
                progress_callback("export_clips", index / max(1, len(candidates)))
        merged_path = None
        if mode == "merge" and files:
            merged_path = output_path or available_output_path(output_dir / "highlights.mp4")
            merged_existed = merged_path.exists()
            concat_file = output_dir / "concat.txt"
            concat_file.write_text(
                "".join(concat_manifest_entry(path) for path in files),
                encoding="utf-8",
            )
            merge_command = [
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                "-f", "concat", "-safe", "0", "-i", str(concat_file),
                "-c", "copy", str(merged_path),
            ]
            try:
                run_atomic_ffmpeg(
                    merge_command,
                    merged_path,
                    cancel_check=cancel_check,
                    process_callback=process_callback,
                )
            except (OSError, subprocess.CalledProcessError):
                # Separate clips use a common encoder, so stream-copy is the
                # fast path. Re-encode only when timestamps/codecs prevent a
                # valid concat output.
                run_atomic_ffmpeg(
                    [
                        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                        "-f", "concat", "-safe", "0", "-i", str(concat_file),
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
                        "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
                        str(merged_path),
                    ],
                    merged_path,
                    cancel_check=cancel_check,
                    process_callback=process_callback,
                )
            if not merged_existed:
                created_files.append(merged_path)
            if progress_callback:
                progress_callback("merge_clips", 0.98)
        else:
            merged_path = None
    except Exception:
        for path in created_files:
            path.unlink(missing_ok=True)
        raise
    export_files = [merged_path] if merged_path else files
    return {
        "files": [str(path) for path in export_files],
        "clip_files": [str(path) for path in files],
        "duration_ms": sum(int(candidate["review_end_ms"]) - int(candidate["review_start_ms"]) for candidate in candidates),
        "processing_ms": round((time.perf_counter() - started) * 1000),
    }
