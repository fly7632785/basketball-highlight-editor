from __future__ import annotations

import json
import math
import os
import platform
import re
import subprocess
import tempfile
import threading
import time
from collections import deque
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Any, Dict
from uuid import uuid4

from .analysis import PipelineCancelled, terminate_process
from ..diagnostics import log_diagnostic, log_failed_command
from ..media_tools import resolve_media_tool
from .hdr import TONEMAP_FILTER, SDR_TAGS


# NVIDIA, Intel, AMD, then the Windows Media Foundation encoder, which works
# on any GPU and falls back to Microsoft's software encoder.
WINDOWS_HARDWARE_CODECS = ("h264_nvenc", "h264_qsv", "h264_amf", "h264_mf")

# FFmpeg only prints the useful part of a failure (missing decoder, encoder
# init error) in the last few lines, so keep a short tail for the job record.
STDERR_TAIL_LINES = 40

# 导出只会写 MP4；这张表既用来补齐漏写的扩展名，也用来显式告诉 FFmpeg 封装格式。
CONTAINER_BY_SUFFIX = {".mp4": "mp4", ".m4v": "mp4", ".mov": "mp4", ".mkv": "matroska"}
DEFAULT_CONTAINER_SUFFIX = ".mp4"

# 这些错误和编码器无关（封装格式、路径、磁盘、权限），换编码器只会重复同一个
# 失败，还会把真正的原因埋进最后一次尝试里。见 issue #8：
# 临时文件名以 .part 结尾，6 个编码器各报一次 "Unable to choose an output format"。
NON_RETRYABLE_STDERR = (
    "Unable to choose an output format",
    "Error initializing the muxer",
    "Error opening output file",
    "No such file or directory",
    "Permission denied",
    "Read-only file system",
    "No space left on device",
)


class MediaCommandError(subprocess.CalledProcessError):
    """FFmpeg failure that keeps the stderr tail in its message."""

    def __init__(self, returncode: int, command: list[str], stderr_tail: str = ""):
        super().__init__(returncode, command, output=None, stderr=stderr_tail or None)
        self.stderr_tail = stderr_tail

    def __str__(self) -> str:
        # 界面只显示一行，原因放最前面；完整命令太长，会把原因挤掉。
        tail = (self.stderr_tail or "").strip()
        code = self.returncode
        if code >= 2 ** 31:
            # Windows 把 -22 这类退出码按 DWORD 回传，界面要显示 -22 而不是 4294967274。
            code -= 2 ** 32
        message = f"ffmpeg 退出码 {code}"
        return f"{message}: {tail}" if tail else message


# 编码器没编进这份 FFmpeg（Windows 随包的 LGPL 版没有 libx264）时，FFmpeg 8 也会接着报
# "Error opening output file"，这种情况必须继续换下一个编码器。
MISSING_ENCODER_STDERR = ("Unknown encoder", "Encoder not found")


def is_retryable_failure(exc: subprocess.CalledProcessError) -> bool:
    """这个失败值得换编码器重试吗？环境类错误换哪个编码器都一样。"""
    tail = getattr(exc, "stderr_tail", "") or ""
    if any(marker in tail for marker in MISSING_ENCODER_STDERR):
        return True
    return not any(marker in tail for marker in NON_RETRYABLE_STDERR)


def normalize_output_path(path: Path) -> Path:
    """导出统一写 MP4；用户漏写扩展名时补上。

    不能用 with_suffix：名字里的点会被当成扩展名，把 "BHE.highlights-261003"
    变成 "BHE.mp4"。
    """
    if path.suffix.lower() in CONTAINER_BY_SUFFIX:
        return path
    return path.with_name(f"{path.name}{DEFAULT_CONTAINER_SUFFIX}")


def ensure_writable_directory(directory: Path) -> None:
    """导出前自检：目录能建、能写。失败时给一句人话，而不是等编码跑完再猜 muxer 报错。"""
    try:
        directory.mkdir(parents=True, exist_ok=True)
        handle, probe = tempfile.mkstemp(prefix=".bhe-export-probe-", dir=str(directory))
        os.close(handle)
    except OSError as exc:
        raise OSError(f"导出位置不可用：{directory}（{exc.strerror or exc}）") from exc
    try:
        Path(probe).unlink(missing_ok=True)
    except OSError:
        # 探针删不掉不影响导出，别把它当成"位置不可用"。
        pass


def validate_output_file(path: Path) -> Path:
    """校验并归一化导出文件路径，返回真正要写的路径。"""
    if path.is_dir():
        raise OSError(f"导出目标是文件夹，需要写文件名：{path}")
    target = normalize_output_path(path)
    ensure_writable_directory(target.parent)
    return target


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
            if index == len(codecs) - 1 or not is_retryable_failure(exc):
                raise
            log_diagnostic(f"encoder {codec} failed, trying {codecs[index + 1]}: {exc}")


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
    tonemap: bool = False,
    portrait: str | None = None,
) -> list[str]:
    """一条 ffmpeg 命令完成：切段、慢放、拼接、回放。所有段统一到同一个尺寸和音频格式再拼。"""
    width, height = (1080, 1920) if portrait else (frame_size or spec["size"])
    fit = (
        f"scale={width}:{height}:force_original_aspect_ratio=decrease,"
        f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1"
    )
    color_filter = f"{TONEMAP_FILTER}," if tonemap else ""
    portrait_prefix = f"{portrait}," if portrait else ""
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
            f"[0:v:0]setpts=PTS-STARTPTS,{portrait_prefix}trim=start={t0 / 1000:.3f}:end={t1 / 1000:.3f},{pace},{color_filter}{fit}[v{index}]"
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
        if portrait:
            offset = (replay["start_ms"] - start_ms) / 1000
            replay_filter = (f"setpts=PTS-STARTPTS+{offset:.3f}/TB,{portrait},"
                             f"setpts=(PTS-STARTPTS)/{REPLAY_SPEED},{color_filter}")
        else:
            replay_filter = (f"setpts=(PTS-STARTPTS)/{REPLAY_SPEED},{color_filter}"
                             f"crop={crop_width}:{crop_height}:{crop_x}:{crop_y},")
        graph.append(
            f"[1:v:0]{replay_filter}"
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
        *codec_options, *(SDR_TAGS if tonemap else []), *(["-c:a", "aac", "-b:a", "128k"] if audio else []),
        "-movflags", "+faststart", str(output_path),
    ]


def build_clip_command(
    source_video: Path,
    start_ms: int,
    end_ms: int,
    output_path: Path,
    video_codec: str | None = None,
    frame_size: tuple[int, int] | None = None,
    effect: Dict[str, Any] | None = None,
    uniform_audio: bool = False,
    has_audio: bool = True,
    tonemap: bool = False,
    frame_rate: str | None = None,
    portrait: str | None = None,
    merge: bool = False,
) -> list[str]:
    if start_ms < 0 or end_ms <= start_ms:
        raise ValueError("INVALID_CLIP_RANGE")
    duration = (end_ms - start_ms) / 1000
    codec = video_codec or video_codecs()[0]
    codec_options = video_codec_options(codec)
    if effect:
        command = _effect_command(source_video, start_ms, end_ms, output_path, codec_options, frame_size, effect, tonemap, portrait)
        return _with_frame_rate(command, frame_rate, merge)
    command = [
        resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
        "-ss", f"{start_ms / 1000:.3f}", "-i", str(source_video),
        "-t", f"{duration:.3f}",
        # Only the first audio track: iPhone spatial audio (APAC) and similar
        # tracks have no decoder here and would abort the whole export.
        # An optional map only skips absent streams; an existing track with
        # an unknown codec still fails. Honor the inspected audio metadata.
        "-map", "0:v:0?",
        *(["-map", "0:a:0?"] if has_audio else ["-an"]),
        *(
            ["-vf", ",".join(filter(None, [
                TONEMAP_FILTER if tonemap else None,
                (portrait if merge else f"setpts=PTS-STARTPTS,{portrait}") if portrait else None,
                (f"scale={frame_size[0]}:{frame_size[1]}:force_original_aspect_ratio=decrease,"
                 f"pad={frame_size[0]}:{frame_size[1]}:(ow-iw)/2:(oh-ih)/2,setsar=1") if frame_size else None,
            ]))] if tonemap or frame_size or portrait else []
        ),
        *codec_options,
        *(SDR_TAGS if tonemap else []),
        *(["-c:a", "aac", "-b:a", "128k"] if has_audio else []),
        # 开了慢放时，带回放的片段音频是 48kHz 立体声；没有回放的片段也统一成这样才能直接拼接。
        *(["-ar", "48000", "-ac", "2"] if uniform_audio and has_audio else []),
        "-movflags", "+faststart", str(output_path),
    ]
    return _with_frame_rate(command, frame_rate, merge)


def _with_frame_rate(command: list[str], frame_rate: str | None, merge: bool) -> list[str]:
    options = ["-r", frame_rate] if frame_rate else []
    if merge:
        options += ["-video_track_timescale", str(MERGE_VIDEO_TIMESCALE)]
        if not frame_rate:
            # Preserve recorded VFR presentation times up to an MP4 clock tick.
            options += ["-fps_mode", "vfr", "-enc_time_base", f"1:{MERGE_VIDEO_TIMESCALE}"]
    return [*command[:-1], *options, command[-1]]


def _frame_rate_text(fps: float) -> str:
    """把 59.94 这类浮点帧率还原成 60000/1001 这样的精确分数，时间基才能对上。"""
    for base in (24, 30, 48, 60, 120):
        if abs(fps - base * 1000 / 1001) < 0.02:
            return f"{base * 1000}/1001"
    ratio = Fraction(fps).limit_denominator(1001)
    return f"{ratio.numerator}/{ratio.denominator}"


def _check_export_cancelled(cancel_check) -> None:
    if cancel_check and cancel_check():
        raise PipelineCancelled("JOB_CANCELLED")


def _run_export_probe(command: list[str], timeout: int, cancel_check=None, process_callback=None) -> str:
    options = dict(stdin=subprocess.DEVNULL, text=True, encoding="utf-8", errors="replace")
    if cancel_check is None and process_callback is None:
        return subprocess.run(command, check=True, capture_output=True, timeout=timeout, **options).stdout

    _check_export_cancelled(cancel_check)
    if os.name == "nt":
        options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
    else:
        options["start_new_session"] = True
    deadline = time.monotonic() + timeout
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **options) as process:
        try:
            if process_callback:
                process_callback(process)
            while True:
                _check_export_cancelled(cancel_check)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    stdout, stderr = process.communicate(timeout=min(0.05, remaining))
                    break
                except subprocess.TimeoutExpired:
                    continue
            _check_export_cancelled(cancel_check)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, command, stdout, stderr)
            return stdout
        finally:
            try:
                if process.poll() is None:
                    terminate_process(process)
            finally:
                if process_callback:
                    process_callback(None)


def _source_frame_rate(path: Path, **probe_options) -> float:
    stream = _run_export_probe(
        [resolve_media_tool("ffprobe"), "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=r_frame_rate", "-of", "default=nw=1:nk=1", str(path)],
        timeout=15, **probe_options,
    ).strip()
    return float(Fraction(stream))


def _merge_frame_rate(candidates: list[Dict[str, Any]], candidate: Dict[str, Any]) -> str | None:
    fps = float(candidate["fps"])
    target = max(float(item["fps"]) for item in candidates)
    same_60fps_group = abs(target - 60) < .02 and abs(fps - 60000 / 1001) < .02
    return _frame_rate_text(target) if target - fps > .005 and not same_60fps_group else None


MERGE_VIDEO_TIMESCALE = 60000
MERGE_AUDIO_RATE = 48000
_VIDEO_FORMAT_FIELDS = (
    "codec_name", "codec_tag_string", "profile", "width", "height", "pix_fmt", "sample_aspect_ratio",
    "time_base", "color_range", "color_space", "color_transfer", "color_primaries", "extradata_hash",
)


@dataclass(frozen=True)
class MergeClip:
    path: Path
    video_format: dict
    pts: tuple[Fraction, ...]
    end: Fraction
    audio: dict | None
    starts_with_keyframe: bool

    @property
    def duration(self) -> Fraction:
        return self.end - self.pts[0]

    @property
    def geometry(self) -> tuple:
        return tuple(self.video_format.get(field) for field in ("width", "height", "sample_aspect_ratio"))

    @property
    def time_base(self) -> Fraction:
        return Fraction(self.video_format["time_base"])


class MergeTimingError(OSError):
    def __init__(self) -> None:
        super().__init__("合并成品流或时长校验失败")


def _probe_merge_clip(path: Path, **probe_options) -> MergeClip:
    result = _run_export_probe(
        [resolve_media_tool("ffprobe"), "-v", "error", "-show_data_hash", "sha256",
         "-show_entries", "stream=index,codec_type,start_time,duration,sample_rate,channel_layout,"
         + ",".join(_VIDEO_FORMAT_FIELDS) + ":packet=stream_index,pts,duration,flags",
         "-of", "json", str(path)],
        timeout=60, **probe_options,
    )
    data = json.loads(result)
    video = next((stream for stream in data["streams"] if stream["codec_type"] == "video"), None)
    if video is None:
        raise MergeTimingError()
    audio = next((stream for stream in data["streams"] if stream["codec_type"] == "audio"), None)
    time_base = Fraction(video["time_base"])
    packets = sorted(
        (int(packet["pts"]), int(packet.get("duration", 0)), packet["flags"])
        for packet in data["packets"]
        if packet["stream_index"] == video["index"] and "D" not in packet["flags"]
    )
    if (not packets or packets[-1][1] <= 0
            or any(right[0] <= left[0] for left, right in zip(packets, packets[1:]))):
        raise MergeTimingError()
    return MergeClip(
        path, {field: video.get(field) for field in _VIDEO_FORMAT_FIELDS},
        tuple(packet[0] * time_base for packet in packets),
        (packets[-1][0] + packets[-1][1]) * time_base, audio, "K" in packets[0][2],
    )


def _seconds(time: Fraction) -> str:
    return f"{float(time):.6f}"


def _merge_command(
    clips: list[MergeClip], offsets: list[Fraction], output: Path, manifest: Path | None,
    audio: tuple[int, str] | None, normalize_color: bool, codec: str | None,
) -> list[str]:
    command = [resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error", "-copyts"]
    graph = []
    if manifest is not None:
        command += ["-f", "concat", "-safe", "0", "-i", str(manifest)]
    if manifest is None or audio:
        command += [arg for clip in clips for arg in ("-i", str(clip.path))]
    if manifest is None:
        width, height, _ = clips[0].geometry
        fit = ""
        if any(clip.geometry != clips[0].geometry for clip in clips[1:]):
            # Fit the displayed shape into the common canvas before declaring
            # square pixels. Replacing only SAR would stretch anamorphic media.
            fit = (f"scale=w='max(2,2*round(min({width},{height}*dar)/2))':"
                   f"h='max(2,2*round(min({height},{width}/dar)/2))'")
            if normalize_color:
                fit += ":in_range=auto:out_range=tv,format=yuv420p"
            fit += f",pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1,"
        elif normalize_color:
            fit = "scale=in_range=auto:out_range=tv,format=yuv420p,"
        for index, offset in enumerate(offsets):
            graph.append(f"[{index}:v:0]{fit}settb=1/{MERGE_VIDEO_TIMESCALE},"
                         f"setpts=PTS-STARTPTS+{round(offset * MERGE_VIDEO_TIMESCALE)}[v{index}]")
        video_inputs = "".join(f"[v{index}]" for index in range(len(clips)))
        graph.append(f"{video_inputs}interleave=n={len(clips)}[video]")
    if audio:
        rate, layout = audio
        for index, clip in enumerate(clips):
            # Prime and encode AAC once for the whole timeline. Each decoded
            # track is trimmed/padded on the video interval in source time.
            if clip.audio is None:
                source = f"anullsrc=r={rate}:cl={layout}"
            else:
                input_index = index + int(manifest is not None)
                source = (f"[{input_index}:a:0]asetpts=PTS-({_seconds(clip.pts[0])})/TB,"
                          f"atrim=start=0:end={_seconds(clip.duration)},"
                          f"aresample={rate}:async=1:first_pts=0,"
                          f"aformat=channel_layouts={layout},"
                          f"apad=whole_dur={_seconds(clip.duration)}")
            graph.append(f"{source},atrim=duration={_seconds(clip.duration)},asetpts=PTS-STARTPTS[a{index}]")
        audio_inputs = "".join(f"[a{index}]" for index in range(len(clips)))
        graph.append(f"{audio_inputs}concat=n={len(clips)}:v=0:a=1[audio]")
    if graph:
        command += ["-filter_complex", ";".join(graph)]
    command += ["-map", "0:v:0" if manifest else "[video]"]
    if audio:
        command += ["-map", "[audio]", "-c:a", "aac", "-b:a", "128k"]
    if manifest is not None:
        command += ["-c:v", "copy"]
    else:
        command += [*video_codec_options(codec), "-fps_mode", "passthrough",
                    "-enc_time_base", f"1:{MERGE_VIDEO_TIMESCALE}"]
        if normalize_color:
            command += SDR_TAGS
    return [*command, "-avoid_negative_ts", "disabled",
            "-video_track_timescale", str(MERGE_VIDEO_TIMESCALE),
            "-movflags", "+faststart", str(output)]


def _merge_encoded_clips(
    files: list[Path], output: Path, codecs: list[str], normalize_color: bool,
    cancel_check, process_callback,
) -> Fraction:
    probe_options = dict(cancel_check=cancel_check, process_callback=process_callback)
    clips = [_probe_merge_clip(path, **probe_options) for path in files]
    offsets = []
    end = Fraction(0)
    for clip in clips:
        offsets.append(end)
        end += clip.duration
    layouts = {(int(clip.audio["sample_rate"]), clip.audio.get("channel_layout")) if clip.audio else None
               for clip in clips}
    audio = None
    if layouts != {None}:
        same_layout = next(iter(layouts)) if len(layouts) == 1 else None
        audio = same_layout if same_layout and same_layout[1] else (MERGE_AUDIO_RATE, "stereo")
    copy_video = not normalize_color and all(
        clip.starts_with_keyframe and clip.video_format == clips[0].video_format for clip in clips
    )

    def validate(path: Path, copied: bool = False) -> None:
        finished = _probe_merge_clip(path, **probe_options)
        audio_tolerance = Fraction(1024, audio[0]) if audio else 0
        if (len(finished.pts) != sum(len(clip.pts) for clip in clips)
                or abs(finished.end - end) > clips[-1].end - clips[-1].pts[-1]
                or (audio and (finished.audio is None
                               or abs(Fraction(finished.audio["start_time"])) > audio_tolerance
                               or abs(Fraction(finished.audio["duration"]) - end) > audio_tolerance))):
            raise MergeTimingError()

        rounded_offset = Fraction(0)
        actual_pts = iter(finished.pts)
        muxer_time_base = finished.time_base
        for clip, offset in zip(clips, offsets):
            _check_export_cancelled(cancel_check)
            shift = offset - clip.pts[0]
            if copied:
                # FFconcat sums the microsecond duration literals, subtracts
                # the rounded inpoint and then rescales to the packet clock.
                manifest_shift = rounded_offset - Fraction(_seconds(clip.pts[0]))
                tolerance = abs(manifest_shift - shift) + clip.time_base / 2
                if clip.time_base != muxer_time_base:
                    tolerance += muxer_time_base / 2
                rounded_offset += Fraction(_seconds(clip.duration))
            else:
                # The filter clock and the muxer each round to their nearest tick.
                tolerance = Fraction(1, 2 * MERGE_VIDEO_TIMESCALE) + muxer_time_base / 2
            if any(abs(next(actual_pts) - pts - shift) > tolerance for pts in clip.pts):
                raise MergeTimingError()

    if copy_video:
        manifest = output.parent / f".bhe-concat-{uuid4().hex}.txt"
        try:
            # Use video PTS at both ends. The demuxer's automatic file duration
            # otherwise includes audio padding and leaves a hole at the seam.
            manifest.write_text(
                "".join(concat_manifest_entry(clip.path) + f"inpoint {_seconds(clip.pts[0])}\n"
                        f"duration {_seconds(clip.duration)}\n" for clip in clips), encoding="utf-8",
            )
            run_atomic_ffmpeg(
                _merge_command(clips, offsets, output, manifest, audio, False, None), output,
                validate_output=lambda path: validate(path, copied=True), **probe_options,
            )
        except MergeTimingError as exc:
            log_diagnostic(f"merge copy failed timing validation, re-encoding: {exc}")
        else:
            return end
        finally:
            manifest.unlink(missing_ok=True)
    run_encoded_ffmpeg(
        lambda codec: _merge_command(clips, offsets, output, None, audio, normalize_color, codec),
        output, codecs, validate_output=validate, **probe_options,
    )
    return end


def validate_media_file(path: Path, **probe_options) -> None:
    if not path.is_file() or path.stat().st_size <= 0:
        raise OSError(f"导出文件为空: {path}")
    command = [
        resolve_media_tool("ffprobe"), "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", str(path),
    ]
    for attempt, timeout in enumerate((15, 60)):
        try:
            result = _run_export_probe(command, timeout, **probe_options)
            break
        except subprocess.TimeoutExpired:
            if attempt:
                raise
            log_diagnostic("export validation ffprobe timed out after 15s; retrying once (60s)")
    try:
        duration = float(result.strip())
    except ValueError as exc:
        raise OSError(f"导出文件时长无效: {path}") from exc
    if duration <= 0:
        raise OSError(f"导出文件时长为零: {path}")


def run_atomic_ffmpeg(
    command: list[str],
    output_path: Path,
    cancel_check=None,
    process_callback=None,
    validate_output=None,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    # 后缀不可信：漏写扩展名、"BHE.highlights-261003" 这类带点的名字都会让临时
    # 文件以 ".part" 收尾，FFmpeg 直接 "Unable to choose an output format" 退出。
    suffix = output_path.suffix.lower()
    if suffix not in CONTAINER_BY_SUFFIX:
        suffix = DEFAULT_CONTAINER_SUFFIX
    temporary = output_path.with_name(
        f".{output_path.stem}.{uuid4().hex}.part{suffix}"
    )
    # 临时文件名之外再显式指定封装格式，双保险。
    atomic_command = [*command[:-1], "-f", CONTAINER_BY_SUFFIX[suffix], str(temporary)]
    try:
        _check_export_cancelled(cancel_check)
        popen_kwargs = {
            "stdin": subprocess.DEVNULL,
            "stderr": subprocess.PIPE,
            "text": True,
            "encoding": "utf-8",
            "errors": "replace",
        }
        if platform.system() == "Windows":
            popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            popen_kwargs["start_new_session"] = True
        process = subprocess.Popen(atomic_command, **popen_kwargs)
        # Drain stderr in a thread so a full pipe can never block FFmpeg.
        stderr_tail: deque[str] = deque(maxlen=STDERR_TAIL_LINES)
        stderr_stream = getattr(process, "stderr", None)
        reader = None
        if stderr_stream is not None:
            reader = threading.Thread(
                target=_collect_stderr,
                args=(stderr_stream, stderr_tail),
                name="ffmpeg-stderr",
                daemon=True,
            )
            reader.start()
        if process_callback:
            process_callback(process)
        try:
            while process.poll() is None:
                if cancel_check and cancel_check():
                    terminate_process(process)
                    raise PipelineCancelled("JOB_CANCELLED")
                time.sleep(0.05)
            _check_export_cancelled(cancel_check)
            if process.returncode != 0:
                if reader is not None:
                    reader.join(timeout=2)
                raise MediaCommandError(
                    process.returncode,
                    atomic_command,
                    "\n".join(stderr_tail),
                )
        finally:
            if process_callback:
                process_callback(None)
            if stderr_stream is not None:
                stderr_stream.close()
        validate_media_file(temporary, cancel_check=cancel_check, process_callback=process_callback)
        if validate_output:
            validate_output(temporary)
        _check_export_cancelled(cancel_check)
        temporary.replace(output_path)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        log_failed_command("media command failed", atomic_command, getattr(exc, "returncode", None))
        raise
    finally:
        temporary.unlink(missing_ok=True)


def merge_overlapping_candidates(candidates, *, keep_portrait_events=False):
    sources = {}
    for index, candidate in enumerate(candidates):
        if int(candidate["review_start_ms"]) < 0 or int(candidate["review_end_ms"]) <= int(candidate["review_start_ms"]):
            raise ValueError("INVALID_CLIP_RANGE")
        sources.setdefault(candidate["source_path"], []).append((index, candidate))
    groups = []
    for members in sources.values():
        current = []
        end = None
        for index, candidate in sorted(members, key=lambda item: int(item[1]["review_start_ms"])):
            start = int(candidate["review_start_ms"])
            if current and start > end:
                groups.append(current)
                current = []
            current.append((index, candidate))
            end = max(end, int(candidate["review_end_ms"])) if len(current) > 1 else int(candidate["review_end_ms"])
        if current:
            groups.append(current)
    merged = []
    for group in sorted(groups, key=lambda group: min(item[0] for item in group)):
        first = min(group, key=lambda item: item[0])[1]
        combined = {
            **first,
            "review_start_ms": min(int(item[1]["review_start_ms"]) for item in group),
            "review_end_ms": max(int(item[1]["review_end_ms"]) for item in group),
            "has_audio": all(bool(item[1].get("has_audio", True)) for item in group),
        }
        if keep_portrait_events:
            combined["portrait_events_ms"] = sorted({
                event for _, candidate in group if not candidate.get("manual")
                for event in candidate.get("portrait_events_ms", [candidate.get("event_time_ms")])
                if event is not None
            })
        merged.append(combined)
    return merged


def _compatible_color_streams(paths: list[Path], **probe_options) -> bool:
    """Mixed-source concat must not stream-copy incompatible color streams."""
    streams = []
    try:
        for path in paths:
            result = _run_export_probe(
                [resolve_media_tool("ffprobe"), "-v", "error", "-select_streams", "v:0",
                 "-show_entries", "stream=codec_name,pix_fmt,width,height,color_space,color_transfer,color_primaries,color_range",
                 "-of", "json", str(path)],
                timeout=15, **probe_options,
            )
            stream = json.loads(result)["streams"][0]
            fields = ("codec_name", "pix_fmt", "width", "height", "color_space", "color_transfer", "color_primaries", "color_range")
            values = tuple(stream.get(field) for field in fields)
            if any(value in (None, "unknown", "unspecified") for value in values):
                return False
            streams.append(values)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError):
        return False
    return bool(streams) and all(item == streams[0] for item in streams)


def export_goal_clips(
    candidates: list[Dict[str, Any]],
    output_dir: Path,
    mode: str,
    output_path: Path | None = None,
    progress_callback=None,
    cancel_check=None,
    process_callback=None,
    effect: str = "none",
    framing: str = "original",
) -> Dict[str, Any]:
    # Old export checkpoints may still carry the retired layout identifier.
    if framing == "portrait_blur":
        framing = "portrait_916"
    if framing not in {"original", "portrait_916"}:
        raise ValueError("INVALID_EXPORT_FRAMING")
    if mode not in {"separate", "merge"}:
        raise ValueError("INVALID_EXPORT_MODE")
    merged_overlap_count = 0
    if mode == "merge" and effect == "none":
        merged = merge_overlapping_candidates(candidates, keep_portrait_events=framing == "portrait_916")
        merged_overlap_count = len(candidates) - len(merged)
        candidates = merged
    started = time.perf_counter()
    probe_options = dict(cancel_check=cancel_check, process_callback=process_callback)
    output_dir.mkdir(parents=True, exist_ok=True)
    files: list[Path] = []
    created_files: list[Path] = []
    total_ms = 0
    codecs = video_codecs()
    # Clips from a source with another resolution are scaled to the first
    # clip's frame so the merge can stream-copy one consistent format.
    tracker = None
    if framing == "portrait_916" and candidates:
        from .portrait import PortraitTracker
        repo_root = Path(__file__).resolve().parents[4]
        model = repo_root / "models" / "bball_model.pt"
        if not model.is_file():
            model = repo_root / "third_party" / "basketball-shot-detection" / "bball_model.pt"
        tracker = PortraitTracker(model)
    if mode == "merge" and len({candidate["source_path"] for candidate in candidates}) > 1:
        source_rates = {}
        for candidate in candidates:
            path = candidate["source_path"]
            if candidate.get("fps"):
                source_rates[path] = candidate["fps"]
        for path in {candidate["source_path"] for candidate in candidates} - source_rates.keys():
            source_rates[path] = _source_frame_rate(Path(path), **probe_options)
        candidates = [{**candidate, "fps": source_rates[candidate["source_path"]]} for candidate in candidates]
    else:
        source_rates = {}
    first = candidates[0] if candidates else {}
    target_size = (first.get("width"), first.get("height"))
    try:
        for index, candidate in enumerate(candidates, 1):
            candidate_size = (candidate.get("width"), candidate.get("height"))
            path = available_output_path(output_dir / clip_file_name(index, candidate))
            def tracking_progress(stage, fraction):
                if progress_callback:
                    progress_callback(stage, ((index - 1) + fraction) / max(1, len(candidates)))

            portrait = tracker.track(candidate, cancel_check, tracking_progress) if tracker else None
            spec = effect_spec(candidate, effect)
            total_ms += output_duration_ms(candidate, spec)
            codec = run_encoded_ffmpeg(
                lambda codec: build_clip_command(
                    Path(candidate["source_path"]),
                    int(candidate["review_start_ms"]),
                    int(candidate["review_end_ms"]),
                    path,
                    codec,
                    target_size if not portrait and None not in target_size and candidate_size != target_size else None,
                    spec,
                    uniform_audio=effect != "none",
                    has_audio=bool(candidate.get("has_audio", True)),
                    tonemap=bool(candidate.get("tonemap")),
                    frame_rate=_merge_frame_rate(candidates, candidate) if source_rates else None,
                    merge=mode == "merge",
                    **({"portrait": portrait} if portrait else {}),
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
            merged_path = (
                validate_output_file(output_path) if output_path
                else available_output_path(output_dir / "highlights.mp4")
            )
            merged_existed = merged_path.exists()
            mixed_color = any(c.get("tonemap") for c in candidates) and any(
                not c.get("tonemap") for c in candidates
            )
            normalize_color = mixed_color and not _compatible_color_streams(files, **probe_options)
            duration = _merge_encoded_clips(files, merged_path, codecs, normalize_color, cancel_check, process_callback)
            total_ms = round(duration * 1000)
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
        "duration_ms": total_ms,
        "merged_overlap_count": merged_overlap_count,
        "processing_ms": round((time.perf_counter() - started) * 1000),
    }
