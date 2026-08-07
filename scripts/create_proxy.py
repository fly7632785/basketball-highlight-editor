import argparse
import json
import platform
import shutil
import subprocess
from uuid import uuid4
from pathlib import Path


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


def main(args):
    video = Path(args.video).resolve()
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg is required to create a proxy video")

    codec = args.codec
    if codec == "auto":
        codec = "h264_videotoolbox" if platform.system() == "Darwin" else "libx264"
    hwaccel = args.hwaccel
    if hwaccel == "auto":
        hwaccel = "videotoolbox" if platform.system() == "Darwin" else "none"
    command = [ffmpeg, "-y"]
    if hwaccel != "none":
        command += ["-hwaccel", hwaccel]
    command += ["-i", str(video)]
    if args.duration is not None:
        command += ["-t", str(args.duration)]
    command += [
        "-vf", f"scale={args.width}:{args.height}:flags=lanczos,fps={args.fps}",
        "-an", "-map_metadata", "-1", "-fps_mode", "cfr",
        "-c:v", codec,
    ]
    if codec == "libx264":
        command += ["-preset", "veryfast", "-crf", "28"]
    else:
        command += ["-b:v", "2M"]
    temporary = output.with_name(f".{output.stem}.{uuid4().hex}.part{output.suffix}")
    temporary_metadata = output.with_suffix(output.suffix + f".{uuid4().hex}.part")
    command.append(str(temporary))
    try:
        subprocess.run(command, check=True)
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
