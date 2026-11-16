"""Opt-in desktop rim experiments. Default decisions remain rim-dense-v2."""
from dataclasses import asdict, dataclass
import hashlib
import json
import math
import os
from statistics import median

from . import rim_check as rc

ENV_NAME = "BHE_RIM_EXPERIMENTS"


@dataclass(frozen=True)
class RimExperiments:
    min_rim_width_px: float = 30.0
    track_mode: str = "off"
    net_weak: bool = False
    net_weak_ratio: float = 0.3
    net_min_samples: int = 8
    supported_side_exit: bool = False

    def __post_init__(self):
        for key, low, high in (("min_rim_width_px", 1, 1000), ("net_weak_ratio", 0, 1)):
            value = getattr(self, key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not low <= value <= high:
                raise ValueError(f"Invalid rim experiment {key}")
        if self.track_mode not in ("off", "fable_stitch", "astra_fill"):
            raise ValueError("Invalid rim experiment track_mode")
        if type(self.net_weak) is not bool or type(self.supported_side_exit) is not bool:
            raise ValueError("Rim experiment switches must be JSON booleans")
        if type(self.net_min_samples) is not int or self.net_min_samples < 8:
            raise ValueError("net_min_samples must be an integer >= 8")

    @property
    def is_default(self):
        return self == RimExperiments()

    def to_dict(self):
        # Canonical numeric representation: 30 and 30.0 are the same experiment.
        return {**asdict(self), "min_rim_width_px": float(self.min_rim_width_px), "net_weak_ratio": float(self.net_weak_ratio)}

    @property
    def config_hash(self):
        return hashlib.sha256(json.dumps(self.to_dict(), sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def load_config(value=None):
    if value is None:
        value = os.environ.get(ENV_NAME, "{}")
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict):
        raise ValueError("Rim experiment config must be a JSON object")
    return RimExperiments(**value)


def consecutive_static(frames, radius=0.12, min_frames=6):
    flat = [(i, ball) for i, balls in enumerate(frames) for ball in balls]
    removed = set()
    for i, ball in flat:
        hits = {j for j, other in flat if abs(other["x"]-ball["x"]) <= radius and abs(other["y"]-ball["y"]) <= radius}
        lo = hi = i
        while lo-1 in hits:
            lo -= 1
        while hi+1 in hits:
            hi += 1
        if hi-lo+1 >= min_frames:
            removed.add(id(ball))
    return [[ball for ball in balls if id(ball) not in removed] for balls in frames]


def stitch_tracks(tracks, fps):
    """Unique upper/lower fragments only; time limits equal 13..35 frames at 30fps."""
    if not _finite(fps) or fps <= 0:
        return tracks, []
    candidates = []
    for a, upper in enumerate(tracks):
        end = upper[-1]
        if not (-0.6 <= end["y"] < 0 and abs(end["x"]) <= .5):
            continue
        for b, lower in enumerate(tracks):
            first = lower[0]
            gap = first["i"] - end["i"]
            if (a != b and 12/30 < gap/fps <= 35/30 and 0 <= first["y"] <= 1 and abs(first["x"]) <= .6 and lower[-1]["y"]-first["y"] >= .5):
                candidates.append((a, b, gap))
    accepted = [(a,b,gap) for a,b,gap in candidates if sum(x==a for x,_,_ in candidates)==1 and sum(y==b for _,y,_ in candidates)==1]
    used = set()
    joined = []
    events = []
    for a,b,gap in accepted:
        if a in used or b in used:
            continue
        used.update((a,b))
        joined.append(tracks[a]+tracks[b])
        events.append({"upper_track": a, "lower_track": b, "gap_frames": gap, "gap_seconds": round(gap/fps, 6)})
    return [t for i,t in enumerate(tracks) if i not in used]+joined, events


def _finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def _raw_check(item, raw, config, mode="off", fps=None):
    frames = raw.get("frames")
    rim = item.get("rim")
    if raw.get("status") == "skipped" or not isinstance(frames, list) or rim is None:
        return {key: raw.get(key) for key in ("version", "status", "reason", "rim_width_px")}, []
    if mode == "off":
        return rc.assess_rim_crossing(frames, rim, raw.get("net_motion_series"), min_rim_width=config.min_rim_width_px), []
    if float(rim["width"]) < config.min_rim_width_px or not frames:
        return rc.assess_rim_crossing(frames, rim, raw.get("net_motion_series"), min_rim_width=config.min_rim_width_px), []
    balls = [rc._frame_balls(frame, rim) for frame in frames]
    filtered = consecutive_static(balls) if mode == "astra_fill" else rc._drop_static(balls)
    tracks = rc._build_tracks(filtered)
    events = []
    if mode == "fable_stitch":
        tracks, events = stitch_tracks(tracks, fps)
    return rc._assess_tracks(frames, rim, raw.get("net_motion_series"), tracks), events


def judge_candidates(inputs, results, refined=None, config=None, fps=None):
    """Same ordering as desktop: raw -> video occlusion -> conservative keep.

    Metadata is additive; stripping `experiment` yields the unchanged default result.
    Net calibration is fixed to baseline made results of this analysis run.
    """
    config = config or RimExperiments()
    if len(inputs) != len(results):
        raise ValueError("Rim input/result count mismatch")
    refined = refined if refined is not None else [True] * len(inputs)
    if len(refined) != len(inputs):
        raise ValueError("Rim refined flags count mismatch")
    raw_results = [raw if isinstance(raw, dict) else rc.skipped_result("check_failed") for raw in results]
    baseline_raw = [_raw_check(item, raw, config)[0] for item,raw in zip(inputs,raw_results)]
    baseline = [rc.keep_unless_seen(c, flag) for c,flag in zip(rc.apply_video_occlusion(baseline_raw), refined)]
    values = [c["net_motion"] for c in baseline if c.get("status")=="made" and _finite(c.get("net_motion"))]
    net_median = median(values) if len(values) >= config.net_min_samples else None
    repaired = baseline
    repair_events = [[] for _ in inputs]
    if config.track_mode != "off":
        alternate = [_raw_check(item,raw,config,config.track_mode,fps) for item,raw in zip(inputs,raw_results)]
        repaired = [rc.keep_unless_seen(c,flag) for c,flag in zip(rc.apply_video_occlusion([c for c,_ in alternate]),refined)]
        repair_events = [events for _,events in alternate]
    judged = []
    for item,raw,old,new,events in zip(inputs,raw_results,baseline,repaired,repair_events):
        chosen = old
        hits = []
        notes = []
        if config.min_rim_width_px != 30 and item.get("rim") and config.min_rim_width_px <= float(item["rim"]["width"]) < 30:
            if isinstance(raw.get("frames"), list) and raw.get("status")!="skipped":
                hits.append("min_rim_width_px")
            else:
                notes.append("small_rim_cache_requires_detection")
        if config.track_mode == "fable_stitch":
            if not _finite(fps) or fps <= 0:
                notes.append("stitch_requires_source_fps")
            else:
                chosen = new
        elif config.track_mode == "astra_fill":
            anchored = (old.get("status")=="unsure" and old.get("reason") in ("no_entry","no_exit") and new.get("status")=="made" and _finite(old.get("x_cross")) and _finite(new.get("x_cross")) and abs(old["x_cross"]-new["x_cross"]) <= .12 and abs(old.get("cross_frame",-999)-new.get("cross_frame",999)) <= 1)
            if anchored:
                chosen = new
        # Changing tracks cannot add a rejection, or directly overrule a seen miss.
        if chosen != old:
            hits.append(config.track_mode)
            if old["status"]!="rejected" and chosen["status"]=="rejected":
                chosen = {**chosen,"status":"unsure","reason":"new_negative_needs_review"}
            elif old["status"]=="rejected" and chosen["status"]!="rejected":
                chosen = {**chosen,"status":"unsure","reason":"conflicting_negative_needs_review"}
        if config.supported_side_exit and chosen.get("status")=="rejected" and chosen.get("reason")=="exit_off_center":
            if chosen.get("track_points",0) < 10 or chosen.get("track_span",0) < 1:
                chosen = {**chosen,"status":"rejected" if chosen.get("rebound") else "unsure","reason":"rebound" if chosen.get("rebound") else "short_side_exit_track"}
                hits.append("supported_side_exit")
        if config.net_weak and chosen.get("status")=="made":
            if net_median is None or net_median <= 0:
                notes.append("net_calibration_insufficient")
            elif not _finite(chosen.get("net_motion")):
                chosen = {**chosen,"status":"unsure","reason":"net_missing"}
                hits.append("net_weak")
            elif chosen["net_motion"] < config.net_weak_ratio * net_median:
                chosen = {**chosen,"status":"unsure","reason":"net_weak"}
                hits.append("net_weak")
        chosen = {**chosen,"experiment":{"config":config.to_dict(),"config_hash":config.config_hash,"baseline_status":old.get("status"),"baseline_reason":old.get("reason"),"final_status":chosen.get("status"),"decision_reason":chosen.get("reason") or "observed_rim_crossing","matched_switches":hits,"notes":notes,"stitches":events,"source_fps":fps,"net_calibration":{"scope":"analysis_run_baseline_made","samples":len(values),"median":net_median}}}
        judged.append(chosen)
    return judged
