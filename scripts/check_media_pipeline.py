#!/usr/bin/env python3
"""Exercise proxy creation and export with the packaged media tools."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    os.environ["BHE_RUNTIME_ROOT"] = str(root)
    sys.path[:0] = [str(root / "engine/python"), str(root / "src")]

    from basketball_engine.adapters.export import export_goal_clips, validate_media_file
    from basketball_engine.media_tools import resolve_media_tool

    # Exclude system FFmpeg so the smoke check tests the shipped executables.
    for name in ("ffmpeg", "ffprobe"):
        resolved = Path(resolve_media_tool(name)).resolve()
        if resolved.parent != root / "bin":
            raise RuntimeError(f"Media tool is not bundled: {name}: {resolved}")

    with tempfile.TemporaryDirectory(prefix="bhe-media-check-") as directory:
        work = Path(directory)
        source = work / "source.mp4"
        subprocess.run([
            resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=10:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:v", "mpeg4", "-q:v", "2", "-c:a", "aac", "-shortest", str(source),
        ], check=True)
        proxy = work / "proxy.mp4"
        subprocess.run([
            sys.executable, str(root / "scripts/create_proxy.py"),
            "--video", str(source), "--output", str(proxy),
            "--width", "160", "--height", "120", "--fps", "5",
        ], check=True)
        validate_media_file(proxy)
        candidates = [
            {"source_path": str(source), "event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000},
            {"source_path": str(source), "event_time_ms": 1500, "review_start_ms": 1000, "review_end_ms": 2000},
        ]
        result = export_goal_clips(candidates, work / "export", "merge")
        for path in [*result["clip_files"], *result["files"]]:
            validate_media_file(Path(path))
    print("media-pipeline-check: PASS (bundled proxy, clips, merged export)")


if __name__ == "__main__":
    main()
