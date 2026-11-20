"""Replay fixed outcome candidates through the desktop adapter and a frozen baseline.

No shooter labels, model inference, candidate selection or truth updates.
Outputs are private development artifacts; use a new ignored .cache directory.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import math
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "src"), str(ROOT / "engine/python")]
from basketball_engine.adapters import analysis


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def event_ms(row):
    """Prefer the precise anchor to the rounded display time."""
    value = (
        float(row["event_time_ms"]) if "event_time_ms" in row
        else float(row["event_ms"]) if "event_ms" in row
        else float(row["time"]) * 1000
    )
    if not math.isfinite(value) or value < 0:
        raise ValueError("OUTCOME_TIME_INVALID")
    return round(value)


def indexed(rows, key):
    result = {row[key]: row for row in rows}
    if len(result) != len(rows):
        raise ValueError("OUTCOME_DUPLICATE_ID")
    return result


def align_labels(candidates, labels, anchors=None, allow_unlabeled=False, allow_non_shots=False):
    by_id = indexed(candidates, "id")
    truths = indexed(labels, "candidate_id")
    if not set(truths) <= set(by_id) or (not allow_unlabeled and set(truths) != set(by_id)):
        raise ValueError("OUTCOME_LABEL_ID_MISMATCH")
    anchor_map = indexed(anchors, "candidate_id") if anchors is not None else {}
    output = []
    for cid, label in truths.items():
        non_shot = label.get("is_shot") is False and allow_non_shots
        if not non_shot and label.get("is_shot") is not True:
            raise ValueError("OUTCOME_REQUIRES_EXPLICIT_SHOT")
        outcome = "not_shot" if non_shot else label.get("human_outcome", label.get("shot_outcome"))
        if outcome not in ("made", "missed", "not_shot"):
            raise ValueError("OUTCOME_REQUIRES_EXPLICIT_TRUTH")
        ms = event_ms(by_id[cid])
        time_sources = [label] if any(k in label for k in ("event_time_ms", "event_ms", "time")) else []
        if anchors is not None:
            if cid not in anchor_map:
                raise ValueError("OUTCOME_ANCHOR_ID_MISMATCH")
            time_sources.append(anchor_map[cid])
        if not time_sources or any(abs(event_ms(row) - ms) > 1 for row in time_sources):
            raise ValueError("OUTCOME_EVENT_TIME_MISMATCH")
        output.append({"candidate_id": cid, "event_time_ms": ms, "human_outcome": outcome})
    return output


def load_baseline(root):
    """Load both exact frozen sources, without replacing the installed modules."""
    def load(name, relative):
        spec = importlib.util.spec_from_file_location(name, Path(root) / relative)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    rim = load("basketball_highlight._outcome_baseline_rim", "src/basketball_highlight/rim_check.py")
    adapter = load("basketball_engine.adapters._outcome_baseline_adapter", "engine/python/basketball_engine/adapters/analysis.py")
    for name in ("assess_rim_crossing", "apply_video_occlusion", "keep_unless_seen", "skipped_result"):
        setattr(adapter, name, getattr(rim, name))
    return adapter


def replay(candidates, evidence, adapter=analysis):
    """Keep every candidate in video-wide calibration, even unreviewed ones."""
    if len(evidence.get("results", [])) != len(candidates):
        raise ValueError("OUTCOME_EVIDENCE_COUNT_MISMATCH")
    matches = []
    for candidate in candidates:
        source = candidate.get("anchor_source")
        if source not in ("existing_refined", "refined", "existing_coarse_fallback"):
            raise ValueError("OUTCOME_REFINEMENT_PROVENANCE_MISSING")
        matches.append({
            "time": event_ms(candidate) / 1000,
            "overlay": {"rim": copy.deepcopy(candidate.get("rim") or (candidate.get("overlay") or {}).get("rim"))},
            "coarse_crossing": source == "existing_coarse_fallback",
        })
    started = time.perf_counter()
    adapter.apply_rim_checks(matches, adapter.rim_check_inputs(matches), evidence)
    elapsed = time.perf_counter() - started
    return {c["id"]: m["rim_check"] for c, m in zip(candidates, matches)}, elapsed


def outcome(check):
    return {"made": "made", "rejected": "missed"}.get(check["status"], "unknown")


def metrics(rows, field):
    matrix = {truth: {pred: 0 for pred in ("made", "missed", "unknown")} for truth in ("made", "missed")}
    for row in rows:
        if row["human_outcome"] in matrix:
            matrix[row["human_outcome"]][outcome(row[field])] += 1
    tp, fn, made_unknown = matrix["made"].values()
    fp, tn, missed_unknown = matrix["missed"].values()
    n = sum(sum(counts.values()) for counts in matrix.values())
    non_shots = {pred: sum(row["human_outcome"] == "not_shot" and outcome(row[field]) == pred
                           for row in rows) for pred in ("made", "missed", "unknown")}
    definite = tp + tn + fp + fn
    ratio = lambda a, b: a / b if b else None
    return {
        "n": n, "matrix": matrix, "correct_definite": tp + tn,
        "reviewed_candidates": len(rows), "non_shot_candidates": sum(non_shots.values()),
        "non_shot_predictions": non_shots,
        "automatic_made_precision_all_reviewed": ratio(tp, tp + fp + non_shots["made"]),
        "definite": definite, "false_positive": fp, "false_negative": fn,
        "abstention": made_unknown + missed_unknown,
        "binary_accuracy": ratio(tp + tn, definite),
        "coverage": ratio(definite, n),
        "correct_definite_share": ratio(tp + tn, n),
        "made_precision": ratio(tp, tp + fp),
        "missed_precision": ratio(tn, tn + fn),
    }


def markdown(result):
    pct = lambda value: "n/a" if value is None else f"{value * 100:.4f}%"
    lines = [
        "# Outcome replay", "",
        f"Evaluation role: {result.get('evaluation_role', 'development')}. "
        "Candidate anchors only; development scores are not independent holdout scores.",
        "Unknown/unsure/skipped remain abstentions. No physical-shot deduplication or exhaustive recall claim.", "",
        f"All {result['candidate_count']} candidates participate in video-wide policy; "
        f"{len(result['rows'])} have reviewed labels, including "
        f"{result['current']['non_shot_candidates']} explicit non-shots.",
        "Binary outcome metrics use only explicit made/missed shots; non-shots remain in every replay and row table.",
        f"Non-shot predictions: baseline={result['baseline']['non_shot_predictions']}, current={result['current']['non_shot_predictions']}",
        f"Unscored IDs (not converted to missed): {result['unscored_ids']}", "",
        "| Metric | Frozen baseline | Current |", "|---|---:|---:|",
    ]
    for key in ("n", "correct_definite", "definite", "false_positive", "false_negative", "abstention",
                "binary_accuracy", "coverage", "correct_definite_share", "made_precision", "missed_precision", "automatic_made_precision_all_reviewed"):
        a, b = result["baseline"][key], result["current"][key]
        formatted = [pct(x) if key.endswith(("accuracy", "coverage", "share", "precision")) else str(x) for x in (a, b)]
        lines.append(f"| {key} | {formatted[0]} | {formatted[1]} |")
    lines += ["", f"Previously correct definite predictions regressed: {result['regressed_ids']}", "",
              "| Candidate | Time ms | Human | Baseline | Current | Reason | Speed ratio | Net response ratio |",
              "|---|---:|---|---|---|---|---:|---:|"]
    for row in result["rows"]:
        check = row["current_check"]
        lines.append(f"| {row['candidate_id']} | {row['event_time_ms']} | {row['human_outcome']} | "
                     f"{outcome(row['baseline_check'])} | {outcome(check)} | {check.get('reason')} | "
                     f"{check.get('passage_speed_ratio')} | {check.get('net_response_ratio')} |")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, help="Verify and replay an immutable outcome review bundle")
    parser.add_argument("--candidates", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--labels", type=Path)
    parser.add_argument("--anchors", type=Path, help="Frozen predictions with precise timestamps; never used as truth")
    parser.add_argument("--baseline-root", type=Path,
                        help="Frozen rim-dense-v2 source tree or checkout; required unless --bundle is supplied")
    parser.add_argument("--current-root", type=Path, help="Replay a frozen candidate version instead of working-tree rules")
    parser.add_argument("--allow-non-shots", action="store_true", help="Report explicit non-shots separately, never as missed truth")
    parser.add_argument("--allow-unlabeled", action="store_true")
    parser.add_argument("--evaluation-role", choices=("holdout", "development", "regression"), default="development")
    parser.add_argument("--verify-inputs", action="store_true", help="Also hash the original video/model")
    parser.add_argument("--output", required=True, type=Path, help="New output directory (must not exist)")
    args = parser.parse_args()
    verified = {}
    if args.bundle:
        for relative, expected in read_json(args.bundle / "manifest-sha256.json").items():
            actual = sha256(args.bundle / relative)
            if actual != expected:
                raise ValueError(f"OUTCOME_MANIFEST_MISMATCH: {relative}")
            verified[relative] = actual
        args.candidates = args.bundle / "source/evaluation-candidates.json"
        args.evidence = args.bundle / "source/rim-check-dense.json"
        args.labels = args.bundle / "outcomes-reviewed.jsonl"
        args.baseline_root = args.bundle / "source/engine-baseline"
        if args.verify_inputs:
            provenance = read_json(args.bundle / "provenance.json")
            for path, expected in (
                (provenance["video"], provenance["video_sha256"]),
                (provenance["ball_model"]["path"], provenance["ball_model"]["sha256"]),
            ):
                actual = sha256(path)
                if actual != expected:
                    raise ValueError(f"OUTCOME_INPUT_HASH_MISMATCH: {path}")
                verified[path] = actual
    if not all((args.candidates, args.evidence, args.labels, args.baseline_root)):
        parser.error("Use --bundle or --candidates/--evidence/--labels/--baseline-root")
    candidates = read_json(args.candidates)
    evidence = read_json(args.evidence)
    if Path(candidates["video"]).name != Path(evidence["video"]).name:
        raise ValueError("OUTCOME_VIDEO_MISMATCH")
    labels = ([json.loads(line) for line in args.labels.read_text().splitlines() if line.strip()]
              if args.labels.suffix == ".jsonl" else read_json(args.labels))
    anchors = read_json(args.anchors)["results"] if args.anchors else None
    truth = align_labels(candidates["candidates"], labels, anchors, args.allow_unlabeled, args.allow_non_shots)
    baseline_adapter = load_baseline(args.baseline_root)
    if baseline_adapter.assess_rim_crossing.__globals__["RIM_CHECK_VERSION"] != "rim-dense-v2":
        raise ValueError("OUTCOME_BASELINE_MUST_BE_FROZEN_V2")
    current_adapter = load_baseline(args.current_root) if args.current_root else analysis
    baseline, old_time = replay(candidates["candidates"], evidence, baseline_adapter)
    current, new_time = replay(candidates["candidates"], evidence, current_adapter)
    rows = [{**label, "baseline_check": baseline[label["candidate_id"]],
             "current_check": current[label["candidate_id"]]} for label in truth]
    if args.bundle:
        for row, label in zip(rows, labels):
            if row["baseline_check"] != label["engine_rim_check"]:
                raise ValueError(f"OUTCOME_FROZEN_BASELINE_MISMATCH: {row['candidate_id']}")
    result = {
        "candidate_count": len(candidates["candidates"]),
        "evaluation_role": args.evaluation_role,
        "evaluated_current_source_sha256": {
            name: sha256((args.current_root or ROOT) / name) for name in (
                "src/basketball_highlight/rim_check.py", "engine/python/basketball_engine/adapters/analysis.py")},
        "versions": {"baseline": "rim-dense-v2",
                     "current": current_adapter.assess_rim_crossing.__globals__["RIM_CHECK_VERSION"]},
        "baseline_source_sha256": {name: sha256(args.baseline_root / name) for name in (
            "src/basketball_highlight/rim_check.py", "engine/python/basketball_engine/adapters/analysis.py")},
        "frozen_current_root": str(args.current_root) if args.current_root else None,
        "unscored_ids": sorted(set(current) - {row["candidate_id"] for row in truth}),
        "baseline": metrics(rows, "baseline_check"), "current": metrics(rows, "current_check"),
        "rows": rows,
        "regressed_ids": [row["candidate_id"] for row in rows
                          if outcome(row["baseline_check"]) == row["human_outcome"]
                          and outcome(row["current_check"]) != row["human_outcome"]],
        "seconds": {"baseline_rules": old_time, "current_rules": new_time},
        "evidence": {"device": evidence.get("device"), "elapsed_seconds": evidence.get("elapsed_seconds")},
        "source_sha256": {str(p.relative_to(ROOT)): sha256(p) for p in (
            ROOT / "src/basketball_highlight/rim_check.py", Path(__file__).resolve())},
        "input_sha256": {str(p): sha256(p) for p in (args.candidates, args.evidence, args.labels)},
        "verified_bundle_files": verified,
    }
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    (args.output / "RESULTS.md").write_text(markdown(result))
    print(json.dumps({key: result[key] for key in ("baseline", "current", "regressed_ids", "seconds")}, indent=2))


if __name__ == "__main__":
    main()
