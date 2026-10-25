from __future__ import annotations

import json
import platform
import re
import subprocess
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any, Dict
from uuid import uuid4

from .analysis import PipelineCancelled, terminate_process
from ..diagnostics import log_diagnostic
from ..media_tools import resolve_media_tool


# NVIDIA, Intel, AMD, then the Windows Media Foundation encoder, which works
# on any GPU and falls back to Microsoft's software encoder.
WINDOWS_HARDWARE_CODECS = ("h264_nvenc", "h264_qsv", "h264_amf", "h264_mf")

# FFmpeg only prints the useful part of a failure (missing decoder, encoder
# init error) in the last few lines, so keep a short tail for the job record.
STDERR_TAIL_LINES = 40


class MediaCommandError(subprocess.CalledProcessError):
    """FFmpeg failure that keeps the stderr tail in its message."""

    def __init__(self, returncode: int, command: list[str], stderr_tail: str = ""):
        super().__init__(returncode, command, output=None, stderr=stderr_tail or None)
        self.stderr_tail = stderr_tail

    def __str__(self) -> str:
        # 界面只显示一行，原因放最前面；完整命令太长，会把原因挤掉。
        tail = (self.stderr_tail or "").strip()
        message = f"ffmpeg 退出码 {self.returncode}"
        return f"{message}: {tail}" if tail else message


def _collect_stderr(stream, tail: deque[str]) -> None:
    try:
        for line in stream:
            text = line.rstrip()
            if text:
                tail.append(text)
    except (OSError, ValueError):
        pass


def video_codecs() -> list[str]:
    hardware = {
        "Darwin": ("h264_videotoolbox",),
        "Windows": WINDOWS_HARDWARE_CODECS,
    }.get(platform.system(), ())
    # The bundled Windows LGPL FFmpeg has no libx264. Keep H.264 when
    # available, then use high-quality MPEG-4 rather than failing the export.
    return list(dict.fromkeys((*hardware, "libx264", "libopenh264", "mpeg4")))


def video_codec_options(codec: str) -> list[str]:
    options = ["-c:v", codec]
    if codec == "libx264":
        options += ["-preset", "veryfast", "-crf", "22"]
    elif codec == "libopenh264":
        options += ["-b:v", "8M"]
    elif codec == "mpeg4":
        options += ["-q:v", "2"]
    elif codec in WINDOWS_HARDWARE_CODECS:
        options += ["-b:v", "16M", "-maxrate", "24M", "-bufsize", "32M"]
    return options


def run_encoded_ffmpeg(command_builder, output_path: Path, codecs: list[str], **kwargs) -> str:
    """Encode with the first codec that works and return it."""
    for index, codec in enumerate(codecs):
        try:
            run_atomic_ffmpeg(command_builder(codec), output_path, **kwargs)
            return codec
        except subprocess.CalledProcessError as exc:
            if index == len(codecs) - 1:
                raise
            log_diagnostic(f"encoder {codec} failed, trying {codecs[index + 1]}: {exc}")


def concat_manifest_entry(path: Path) -> str:
    """Render a path safely for the ffmpeg concat demuxer on macOS and Windows."""
    normalized = path.resolve().as_posix().replace("'", "'\\''")
    return f"file '{normalized}'\n"


def merge_existing_videos(
    input_paths: list[Path],
    output_path: Path,
    *,
    cancel_check=None,
    process_callback=None,
) -> Dict[str, Any]:
    """Merge local video files in their supplied order into one MP4."""
    if not input_paths:
        raise ValueError("NO_MERGE_INPUTS")
    inputs = [path.expanduser().resolve() for path in input_paths]
    if any(not path.is_file() or path.stat().st_size <= 0 for path in inputs):
        raise OSError("MERGE_INPUT_NOT_FOUND")
    output = output_path.expanduser().resolve()
    if output in inputs:
        raise ValueError("MERGE_OUTPUT_CONFLICT")

    output.parent.mkdir(parents=True, exist_ok=True)
    manifest = output.with_name(f".{output.stem}.{uuid4().hex}.concat.txt")
    manifest.write_text(
        "".join(concat_manifest_entry(path) for path in inputs), encoding="utf-8"
    )
    try:
        copy_command = [
            resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
            "-f", "concat", "-safe", "0", "-i", str(manifest),
            "-c", "copy", str(output),
        ]
        try:
            run_atomic_ffmpeg(
                copy_command,
                output,
                cancel_check=cancel_check,
                process_callback=process_callback,
            )
        except (OSError, subprocess.CalledProcessError):
            run_encoded_ffmpeg(
                lambda codec: [
                    resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                    "-f", "concat", "-safe", "0", "-i", str(manifest),
                    *video_codec_options(codec), "-c:a", "aac", "-b:a", "128k",
                    "-movflags", "+faststart", str(output),
                ],
                output,
                video_codecs(),
                cancel_check=cancel_check,
                process_callback=process_callback,
            )
    finally:
        manifest.unlink(missing_ok=True)
    return {"files": [str(output)]}


def available_output_path(path: Path) -> Path:
    if not path.exists():
        return path
    for index in range(2, 10_000):
        candidate = path.with_name(f"{path.stem}_{index}{path.suffix}")
        if not candidate.exists():
            return candidate
    raise OSError(f"无法生成不冲突的导出文件名: {path}")


def safe_file_stem(name: object) -> str:
    """去掉不能出现在文件名里的字符，最长 40 个字。"""
    return re.sub(r'[\x00-\x1f<>:"/\\|?*]+', "_", str(name or "")).strip(" ._")[:40]


def clip_file_name(index: int, candidate: Dict[str, Any]) -> str:
    segment = f"_s{candidate['segment']}" if candidate.get("segment") else ""
    name = f"goal_{index:03d}{segment}_{candidate['event_time_ms'] / 1000:.2f}s"
    player = safe_file_stem(candidate.get("player_name"))
    return f"{name}_{player}.mp4" if player else f"{name}.mp4"


# 进球效果，effect 取值：
#   "none"      不加效果；
#   "approach"  临门慢动作：进球前 1 秒到进框后 0.3 秒放慢到 0.5 倍，人和球都在原画面里；
#   "replay"    慢放特写：片段播完后，重播入框前后 0.8 秒，放慢一倍，取景框住篮筐和球路。
EFFECTS = ("none", "approach", "replay")
APPROACH_BEFORE_MS = 1000
APPROACH_AFTER_MS = 300
APPROACH_SPEED = 0.5
REPLAY_BEFORE_MS = 500
REPLAY_AFTER_MS = 300
REPLAY_SPEED = 0.5
REPLAY_MIN_ZOOM = 1.3
REPLAY_MAX_ZOOM = 2.0
MIN_SEGMENT_MS = 300
AUDIO_FORMAT = "aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo"


def _window(candidate: Dict[str, Any], before_ms: int, after_ms: int) -> tuple[int, int] | None:
    """进球时刻前后一段时间，限制在片段范围内；手动片段没有进球时刻，不加效果。"""
    event = candidate.get("event_time_ms")
    if event is None or candidate.get("manual"):
        return None
    start = max(int(candidate["review_start_ms"]), int(event) - before_ms)
    end = min(int(candidate["review_end_ms"]), int(event) + after_ms)
    return (start, end) if end - start >= MIN_SEGMENT_MS else None


def approach_window(candidate: Dict[str, Any]) -> tuple[int, int] | None:
    return _window(candidate, APPROACH_BEFORE_MS, APPROACH_AFTER_MS)


def replay_window(candidate: Dict[str, Any]) -> tuple[int, int] | None:
    return _window(candidate, REPLAY_BEFORE_MS, REPLAY_AFTER_MS)


def trajectory_points(evidence_json: str | None, event_ms: int) -> list[list[float]]:
    """进球前后球的飞行位置（源视频像素），用来决定特写取景。"""
    try:
        overlay = json.loads(evidence_json or "{}").get("overlay") or {}
    except (TypeError, ValueError, AttributeError):
        return []
    start, end = event_ms - REPLAY_BEFORE_MS, event_ms + REPLAY_AFTER_MS
    points = []
    for point in overlay.get("trajectory") or []:
        if not isinstance(point, dict) or point.get("time") is None:
            continue
        if point.get("x") is None or point.get("y") is None:
            continue
        if start <= float(point["time"]) * 1000 <= end:
            points.append([float(point["x"]), float(point["y"])])
    return points


def replay_crop(
    points: list[list[float]], width: int, height: int, aspect: float,
) -> tuple[int, int, int, int] | None:
    """特写裁剪框 (宽, 高, x, y)，宽高比和输出画面一致，框住所有球路点，不出画面。"""
    if not points:
        return None
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    span = max(max(xs) - min(xs), (max(ys) - min(ys)) * aspect) * 1.25
    # 球路点全重合时 span 为 0，除数兜底；显式判断而不是靠 `or`，负数不会被静默放过。
    if span <= 0:
        span = 1.0
    zoom = min(REPLAY_MAX_ZOOM, max(REPLAY_MIN_ZOOM, width / span))
    crop_width = width / zoom
    crop_height = crop_width / aspect
    if crop_height > height:
        crop_height = height
        crop_width = height * aspect
    crop_width, crop_height = int(crop_width) // 2 * 2, int(crop_height) // 2 * 2
    center_x, center_y = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    x = int(min(max(center_x - crop_width / 2, 0), width - crop_width)) // 2 * 2
    y = int(min(max(center_y - crop_height / 2, 0), height - crop_height)) // 2 * 2
    return crop_width, crop_height, x, y


def effect_spec(candidate: Dict[str, Any], effect: str) -> Dict[str, Any] | None:
    """这个片段要加的效果；取不到所需数据（没有进球时刻、尺寸，或没有球路）时返回 None，按原样导出。"""
    if effect not in EFFECTS:
        raise ValueError("INVALID_EXPORT_EFFECT")
    if effect == "none":
        return None
    width, height = candidate.get("width"), candidate.get("height")
    if not width or not height:
        return None
    size = (int(width), int(height))
    base = {
        "size": size,
        "fps": float(candidate.get("fps") or 30.0),
        "has_audio": bool(candidate.get("has_audio", True)),
        "slow": None,
        "replay": None,
    }
    if effect == "approach":
        window = approach_window(candidate)
        return {**base, "slow": window} if window else None
    window = replay_window(candidate)
    if not window:
        return None
    points = list(candidate.get("trail") or [])
    rim = candidate.get("rim") or {}
    if rim.get("width") and rim.get("x") is not None and rim.get("y") is not None:
        half = float(rim["width"]) / 2
        points += [[rim["x"] - half, rim["y"]], [rim["x"] + half, rim["y"]], [rim["x"], rim["y"] - half], [rim["x"], rim["y"] + half]]
    crop = replay_crop(points, size[0], size[1], size[0] / size[1])
    if not crop:
        return None
    return {**base, "replay": {"start_ms": window[0], "end_ms": window[1], "crop": crop}}


def output_duration_ms(candidate: Dict[str, Any], spec: Dict[str, Any] | None) -> int:
    total = int(candidate["review_end_ms"]) - int(candidate["review_start_ms"])
    if spec and spec["slow"]:
        slow_start, slow_end = spec["slow"]
        total += round((slow_end - slow_start) * (1 / APPROACH_SPEED - 1))
    if spec and spec["replay"]:
        replay = spec["replay"]
        total += round((replay["end_ms"] - replay["start_ms"]) / REPLAY_SPEED)
    return total


def _effect_command(
    source_video: Path,
    start_ms: int,
    end_ms: int,
    output_path: Path,
    codec_options: list[str],
    frame_size: tuple[int, int] | None,
    spec: Dict[str, Any],
) -> list[str]:
    """一条 ffmpeg 命令完成：切段、慢放、拼接、回放。所有段统一到同一个尺寸和音频格式再拼。"""
    width, height = frame_size or spec["size"]
    fit = (
        f"scale={width}:{height}:force_original_aspect_ratio=decrease,"
        f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1"
    )
    audio = spec["has_audio"]
    duration_ms = end_ms - start_ms
    cuts: list[tuple[float, float, float]] = []
    if spec["slow"]:
        slow_start, slow_end = spec["slow"]
        cuts = [
            (0, slow_start - start_ms, 1.0),
            (slow_start - start_ms, slow_end - start_ms, APPROACH_SPEED),
            (slow_end - start_ms, duration_ms, 1.0),
        ]
    else:
        cuts = [(0, duration_ms, 1.0)]
    graph: list[str] = []
    pairs: list[str] = []
    for index, (t0, t1, speed) in enumerate(cuts):
        if t1 - t0 <= 0:
            continue
        pace = "setpts=PTS-STARTPTS" if speed == 1.0 else f"setpts=(PTS-STARTPTS)/{speed}"
        graph.append(
            f"[0:v:0]setpts=PTS-STARTPTS,trim=start={t0 / 1000:.3f}:end={t1 / 1000:.3f},{pace},{fit}[v{index}]"
        )
        if audio:
            tempo = "" if speed == 1.0 else f",atempo={speed}"
            graph.append(
                f"[0:a:0]asetpts=PTS-STARTPTS,atrim=start={t0 / 1000:.3f}:end={t1 / 1000:.3f},"
                f"asetpts=PTS-STARTPTS{tempo},{AUDIO_FORMAT}[a{index}]"
            )
        pairs.append(f"[v{index}]" + (f"[a{index}]" if audio else ""))
    command_inputs = [
        "-ss", f"{start_ms / 1000:.3f}", "-t", f"{duration_ms / 1000:.3f}", "-i", str(source_video),
    ]
    if spec["replay"]:
        replay = spec["replay"]
        crop_width, crop_height, crop_x, crop_y = replay["crop"]
        window_s = (replay["end_ms"] - replay["start_ms"]) / 1000
        index = len(pairs)
        command_inputs += [
            "-ss", f"{replay['start_ms'] / 1000:.3f}", "-t", f"{window_s:.3f}", "-i", str(source_video),
        ]
        graph.append(
            f"[1:v:0]setpts=(PTS-STARTPTS)/{REPLAY_SPEED},crop={crop_width}:{crop_height}:{crop_x}:{crop_y},"
            f"fps={spec['fps']:.6f},{fit}[v{index}]"
        )
        if audio:
            # 回放不带声音，和慢放的环境声分开；长度和画面一致。
            graph.append(
                f"anullsrc=r=48000:cl=stereo,atrim=duration={window_s / REPLAY_SPEED:.3f},{AUDIO_FORMAT}[a{index}]"
            )
        pairs.append(f"[v{index}]" + (f"[a{index}]" if audio else ""))
    concat_audio = 1 if audio else 0
    outputs = "[vout]" + ("[aout]" if audio else "")
    graph.append(f"{''.join(pairs)}concat=n={len(pairs)}:v=1:a={concat_audio}{outputs}")
    return [
        resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
        *command_inputs,
        "-filter_complex", ";".join(graph),
        "-map", "[vout]", *(["-map", "[aout]"] if audio else []),
        *codec_options, *(["-c:a", "aac", "-b:a", "128k"] if audio else []),
        "-movflags", "+faststart", str(output_path),
    ]


# Characters Windows rejects in file names. Player names come from user input,
# so one entry must never make the whole export fail.
_INVALID_FILENAME_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def player_filename_prefix(player_name: Any, max_length: int = 48) -> str:
    """Return ``"<player>_"`` for use before ``goal_…``, or ``""`` if unusable."""
    if not isinstance(player_name, str):
        return ""
    name = _INVALID_FILENAME_CHARS.sub("_", player_name.strip())
    name = re.sub(r"\s+", "_", name).strip(" ._")
    name = name[:max_length].rstrip(" ._")
    return f"{name}_" if name else ""


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
    codec = video_codec or video_codecs()[0]
    codec_options = video_codec_options(codec)
    command = [
        resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
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
            resolve_media_tool("ffprobe"), "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        check=True,
        capture_output=True,
        stdin=subprocess.DEVNULL,
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
        popen_kwargs = {"stdin": subprocess.DEVNULL}
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
    total_ms = 0
    codecs = video_codecs()
    # Clips from a source with another resolution are scaled to the first
    # clip's frame so the merge can stream-copy one consistent format.
    first = candidates[0] if candidates else {}
    target_size = (first.get("width"), first.get("height"))
    try:
        for index, candidate in enumerate(candidates, 1):
            candidate_size = (candidate.get("width"), candidate.get("height"))
            path = available_output_path(output_dir / clip_file_name(index, candidate))
            spec = effect_spec(candidate, effect)
            total_ms += output_duration_ms(candidate, spec)
            player_prefix = player_filename_prefix(candidate.get("player_name"))
            path = available_output_path(
                output_dir
                / f"{player_prefix}goal_{index:03d}_{candidate['event_time_ms'] / 1000:.2f}s.mp4"
            )
            codec = run_encoded_ffmpeg(
                lambda codec: build_clip_command(
                    Path(candidate["source_path"]),
                    int(candidate["review_start_ms"]),
                    int(candidate["review_end_ms"]),
                    path,
                    codec,
                    target_size if None not in target_size and candidate_size != target_size else None,
                    spec,
                    uniform_audio=effect != "none",
                ),
                path,
                codecs,
                cancel_check=cancel_check,
                process_callback=process_callback,
            )
            # Later clips start with the encoder that worked, so they skip the
            # failed hardware attempts and share one codec for the merge copy.
            codecs = [codec, *(other for other in codecs if other != codec)]
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
                resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
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
                run_encoded_ffmpeg(
                    lambda codec: [
                        resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                        "-f", "concat", "-safe", "0", "-i", str(concat_file),
                        *video_codec_options(codec),
                        "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
                        str(merged_path),
                    ],
                    merged_path,
                    codecs,
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
