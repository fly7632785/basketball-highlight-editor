import argparse
import json
import platform
import shutil
import subprocess
from uuid import uuid4
from pathlib import Path


def progress_from_ffmpeg_line(line, duration_seconds):
    if not duration_seconds or duration_seconds <= 0:
        return None
    key, separator, raw_value = line.strip().partition("=")
    if not separator or key not in {"out_time_us", "out_time_ms"}:
        return None
    try:
        elapsed_seconds = float(raw_value) / 1_000_000
    except ValueError:
        return None
    return max(0.0, min(1.0, elapsed_seconds / duration_seconds))


def probe_duration(ffprobe, video):
    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(video),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
    )
    return float(result.stdout.strip())


def parse_args():
    parser = argparse.ArgumentParser(description="Create a low-cost CFR proxy for coarse video scanning.")
    parser.add_argument("--video", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--width", type=int, default=960)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--fps", type=float, default=5)
    parser.add_argument("--duration", type=float,
                        help="Optional duration limit, useful for short benchmarks.")
    parser.add_argument("--codec", choices=("auto", "libx264", "h264_videotoolbox"), default="auto")
    parser.add_argument("--hwaccel", choices=("auto", "none", "videotoolbox"), default="auto")
    return parser.parse_args()


def build_proxy_command(
    ffmpeg, video, output, args, codec, hwaccel,
):
    command = [ffmpeg, "-y", "-progress", "pipe:1", "-nostats"]
    if hwaccel != "none":
        command += ["-hwaccel", hwaccel]
    command += ["-i", str(video)]
    if args.duration is not None:
        command += ["-t", str(args.duration)]
    command += [
        "-vf", (
            f"scale={args.width}:{args.height}:"
            f"force_original_aspect_ratio=decrease:flags=lanczos,fps={args.fps}"
        ),
        "-an", "-map_metadata", "-1", "-fps_mode", "cfr",
        "-c:v", codec,
    ]
    if codec == "libx264":
        command += ["-preset", "veryfast", "-crf", "28"]
    else:
        command += ["-b:v", "2M"]
    command.append(str(output))
    return command


def run_proxy_command(command, source_duration):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
    assert process.stdout is not None
    for line in process.stdout:
        progress = progress_from_ffmpeg_line(line, source_duration)
        if progress is not None:
            print(f"progress={progress:.4f}", flush=True)
    return process.wait()


def main(args):
    video = Path(args.video).resolve()
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg is required to create a proxy video")
    ffprobe = shutil.which("ffprobe")
    source_duration = args.duration
    if source_duration is None and ffprobe:
        try:
            source_duration = probe_duration(ffprobe, video)
        except (
            OSError,
            ValueError,
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
        ):
            source_duration = None

    codec = args.codec
    if codec == "auto":
        codec = "h264_videotoolbox" if platform.system() == "Darwin" else "libx264"
    hwaccel = args.hwaccel
    if hwaccel == "auto":
        hwaccel = "videotoolbox" if platform.system() == "Darwin" else "none"
    temporary = output.with_name(f".{output.stem}.{uuid4().hex}.part{output.suffix}")
    temporary_metadata = output.with_suffix(output.suffix + f".{uuid4().hex}.part")
    try:
        attempts = [(codec, hwaccel)]
        if args.codec == "auto" and codec != "libx264":
            attempts.append(("libx264", "none"))
        last_command = None
        for attempt_codec, attempt_hwaccel in attempts:
            temporary.unlink(missing_ok=True)
            last_command = build_proxy_command(
                ffmpeg, video, temporary, args, attempt_codec, attempt_hwaccel,
            )
            returncode = run_proxy_command(last_command, source_duration)
            if returncode == 0:
                codec = attempt_codec
                hwaccel = attempt_hwaccel
                break
        else:
            raise subprocess.CalledProcessError(returncode, last_command)
        print("progress=1.0", flush=True)
        if not temporary.is_file() or temporary.stat().st_size <= 0:
            raise RuntimeError(f"代理视频未生成: {output}")
        temporary.replace(output)

        metadata = {
            "source_video": str(video),
            "source_size_bytes": video.stat().st_size,
            "source_mtime_ns": video.stat().st_mtime_ns,
            "proxy_video": str(output),
            "width": args.width,
            "height": args.height,
            "preserve_aspect_ratio": True,
            "fps": args.fps,
            "duration": args.duration,
            "codec": codec,
            "hwaccel": hwaccel,
            "timestamp_policy": "CFR proxy; source timestamps remain authoritative for final cuts",
        }
        temporary_metadata.write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8",
        )
        temporary_metadata.replace(output.with_suffix(output.suffix + ".json"))
    finally:
        temporary.unlink(missing_ok=True)
        temporary_metadata.unlink(missing_ok=True)
    print(json.dumps(metadata, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main(parse_args())
