import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.audio import event_window_features, merge_time_ranges
from export_review_queue import unique_matches


def parse_args():
    parser = argparse.ArgumentParser(
        description="Extract relative audio features for refined basketball candidates.",
    )
    parser.add_argument("--video", required=True)
    parser.add_argument("--detections", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--dedupe-sec", type=float, default=2.0)
    parser.add_argument("--sample-rate", type=int, default=16000)
    parser.add_argument("--before", type=float, default=1.0)
    parser.add_argument("--after", type=float, default=0.8)
    return parser.parse_args()


def _decode_ranges(video, ranges, sample_rate):
    if not ranges:
        return {}
    first_start = ranges[0][0]
    last_end = ranges[-1][1]
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-ss", f"{first_start:.3f}", "-i", str(video),
        "-t", f"{last_end - first_start:.3f}",
        "-vn", "-ac", "1", "-ar", str(sample_rate),
        "-f", "f32le", "pipe:1",
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    range_buffers = [[] for _ in ranges]
    cursor = first_start
    bytes_per_sample = 4
    chunk_size = 65536 - (65536 % bytes_per_sample)
    while True:
        raw = process.stdout.read(chunk_size)
        if not raw:
            break
        usable = len(raw) - (len(raw) % bytes_per_sample)
        if usable == 0:
            continue
        samples = np.frombuffer(raw[:usable], dtype=np.float32)
        chunk_start = cursor
        chunk_end = cursor + len(samples) / sample_rate
        for index, (start, end) in enumerate(ranges):
            overlap_start = max(chunk_start, start)
            overlap_end = min(chunk_end, end)
            if overlap_end <= overlap_start:
                continue
            first = int(round((overlap_start - chunk_start) * sample_rate))
            last = int(round((overlap_end - chunk_start) * sample_rate))
            range_buffers[index].append(samples[first:last].copy())
        cursor = chunk_end
        if cursor >= last_end:
            break
    stderr = process.communicate()[1]
    if process.returncode != 0:
        raise subprocess.CalledProcessError(process.returncode, command, stderr=stderr)
    return {
        index: np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
        for index, chunks in enumerate(range_buffers)
    }


def extract_candidate_features(video, matches, sample_rate, before, after):
    events = [float(match["time"]) for match in matches]
    ranges = merge_time_ranges([
        (max(0.0, event - before), event + after)
        for event in events
    ])
    decoded = _decode_ranges(video, ranges, sample_rate)
    output = []
    for candidate_id, match in enumerate(matches, 1):
        event = float(match["time"])
        range_index = next(
            index for index, (start, end) in enumerate(ranges)
            if start <= event <= end
        )
        range_start = ranges[range_index][0]
        features = event_window_features(
            decoded[range_index], sample_rate, event - range_start,
        )
        output.append({
            "candidate_id": candidate_id,
            "event_time": round(event, 3),
            "audio": features,
        })
    return output


def main(args):
    video = Path(args.video).resolve()
    detections_path = Path(args.detections).resolve()
    detections = json.loads(detections_path.read_text(encoding="utf-8"))
    matches = unique_matches(detections, args.dedupe_sec)
    features = extract_candidate_features(
        video, matches, args.sample_rate, args.before, args.after,
    )
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "video": str(video),
        "detections": str(detections_path),
        "dedupe_sec": args.dedupe_sec,
        "sample_rate": args.sample_rate,
        "window": {"before": args.before, "after": args.after},
        "candidate_count": len(features),
        "candidates": features,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"candidates={len(features)}")
    print(f"output={output}")


if __name__ == "__main__":
    main(parse_args())
