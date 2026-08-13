import argparse
import csv
import json
import subprocess
from pathlib import Path

from basketball_highlight.events import calibrated_gates
from basketball_highlight.ranking import dedupe_candidates


def parse_args():
    parser = argparse.ArgumentParser(description="Export review clips from refined basketball candidates.")
    parser.add_argument("--video", required=True)
    parser.add_argument("--detections", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--before", type=float, default=6.0)
    parser.add_argument("--after", type=float, default=3.0)
    parser.add_argument("--dedupe-sec", type=float, default=2.0)
    parser.add_argument("--auto-only", action="store_true",
                        help="Export only candidates passing the automatic-goal gate.")
    parser.add_argument("--concat", action="store_true")
    parser.add_argument("--batch-size", type=int, default=0,
                        help="Optional number of candidates per review video.")
    return parser.parse_args()


def video_duration(video):
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(video)],
        check=True, capture_output=True, text=True,
    )
    return float(result.stdout.strip())


def is_automatic_goal(match):
    verdict = match.get("verdict")
    if verdict is not None and verdict != "made":
        return False
    persisted_gates = match.get("gates")
    if isinstance(persisted_gates, dict) and "automatic_goal" in persisted_gates:
        return bool(persisted_gates["automatic_goal"])
    return bool(calibrated_gates(match).get("automatic_goal"))


def unique_matches(data, dedupe_sec, auto_only=False):
    matches = [
        match
        for result in data.get("results", [])
        for match in result.get("refined", [])
    ]
    if auto_only:
        matches = [match for match in matches if is_automatic_goal(match)]
    return dedupe_candidates(matches, dedupe_sec)


def main(args):
    video = Path(args.video).resolve()
    detections = json.loads(Path(args.detections).read_text(encoding="utf-8"))
    output_dir = Path(args.output_dir).resolve()
    clips_dir = output_dir / "clips"
    clips_dir.mkdir(parents=True, exist_ok=True)
    duration = video_duration(video)
    matches = unique_matches(detections, args.dedupe_sec, auto_only=args.auto_only)
    rows = []
    concat_entries = []

    for index, match in enumerate(matches, 1):
        event_time = float(match["time"])
        start = max(0.0, event_time - args.before)
        end = min(duration, event_time + args.after)
        clip_name = f"candidate_{index:03d}_{event_time:010.2f}s.mp4"
        clip_path = clips_dir / clip_name
        if not clip_path.exists():
            subprocess.run([
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                "-ss", f"{start:.3f}", "-i", str(video),
                "-t", f"{end - start:.3f}",
                "-map", "0:v:0?", "-map", "0:a?", "-c", "copy",
                str(clip_path),
            ], check=True)
        rows.append({
            "index": index,
            "event_time": round(event_time, 3),
            "start": round(start, 3),
            "end": round(end, 3),
            "duration": round(end - start, 3),
            "confidence": match.get("confidence"),
            "score": match.get("score"),
            "prediction_review": match.get("gates", {}).get("prediction_review", False),
            "file": str(clip_path),
        })
        concat_entries.append(clip_path)

    index_path = output_dir / "INDEX.csv"
    with index_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()) if rows else ["index"])
        writer.writeheader()
        writer.writerows(rows)

    manifest = {
        "source_video": str(video),
        "detections": str(Path(args.detections).resolve()),
        "before_seconds": args.before,
        "after_seconds": args.after,
        "auto_only": args.auto_only,
        "candidate_count": len(rows),
        "clips": rows,
    }
    (output_dir / "MANIFEST.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8",
    )

    if args.concat and concat_entries:
        batch_size = args.batch_size if args.batch_size > 0 else len(concat_entries)
        for batch_index, start in enumerate(range(0, len(concat_entries), batch_size), 1):
            end = min(len(concat_entries), start + batch_size)
            batch_name = f"BATCH_{batch_index:02d}_{start + 1:03d}-{end:03d}"
            concat_file = output_dir / f"{batch_name}.txt"
            concat_file.write_text(
                "".join(f"file '{path}'\n" for path in concat_entries[start:end]),
                encoding="utf-8",
            )
            subprocess.run([
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                "-f", "concat", "-safe", "0", "-i", str(concat_file),
                "-c", "copy", str(output_dir / f"{batch_name}.mp4"),
            ], check=True)
            with (output_dir / f"{batch_name}_INDEX.csv").open(
                "w", newline="", encoding="utf-8",
            ) as handle:
                writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
                writer.writeheader()
                writer.writerows(rows[start:end])

    print(f"candidates={len(rows)}")
    print(f"output={output_dir}")


if __name__ == "__main__":
    main(parse_args())
