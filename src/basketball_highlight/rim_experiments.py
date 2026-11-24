"""Desktop rim rules with explicit overrides for replay and diagnostics."""
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
    track_mode: str = "off"
    visible_crossing: bool = False

    def __post_init__(self):
        if self.track_mode not in ("off", "fable_stitch"):
            raise ValueError("Invalid rim experiment track_mode")
        if type(self.visible_crossing) is not bool:
            raise ValueError("visible_crossing must be a JSON boolean")

    @property
    def is_default(self):
        return self == RimExperiments()

    def to_dict(self):
        return asdict(self)

    @property
    def config_hash(self):
        return hashlib.sha256(json.dumps(self.to_dict(), sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def load_config(value=None):
    if value is None:
        value = os.environ.get(ENV_NAME)
        if value is None:
            return RimExperiments(track_mode="fable_stitch", visible_crossing=True)
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict):
        raise ValueError("Rim experiment config must be a JSON object")
    return RimExperiments(**value)


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


def _raw_check(item, raw, mode="off", fps=None):
    frames = raw.get("frames")
    rim = item.get("rim")
    if raw.get("status") == "skipped" or not isinstance(frames, list) or rim is None:
        return {key: raw.get(key) for key in ("version", "status", "reason", "rim_width_px")}, []
    net_motion = raw.get("net_motion_series")
    if mode == "off" or float(rim["width"]) < rc.MIN_RIM_WIDTH_PX or not frames:
        return rc.assess_rim_crossing(frames, rim, net_motion), []
    balls = [rc._frame_balls(frame, rim) for frame in frames]
    tracks, events = stitch_tracks(rc._build_tracks(rc._drop_static(balls)), fps)
    return rc._assess_tracks(frames, rim, net_motion, tracks), events


def _is_visible_crossing(check, net_median):
    return (
        check.get("status") == "unsure"
        and check.get("reason") == "not_occluded"
        and check.get("entry") is True
        and check.get("reached_net_bottom") is True
        and check.get("rebound") is False
        and all(_finite(check.get(key)) for key in ("x_cross", "x_exit", "net_motion"))
        and check.get("track_points", 0) >= rc.MIN_OFF_CENTER_TRACK_POINTS
        and max(abs(check["x_cross"]), abs(check["x_exit"])) <= .25
        and check["net_motion"] > 0
        and net_median is not None
        and net_median > 0
        and check["net_motion"] >= .3 * net_median
    )


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
    baseline_raw = [_raw_check(item, raw)[0] for item,raw in zip(inputs,raw_results)]
    baseline = [rc.keep_unless_seen(c, flag) for c,flag in zip(rc.apply_video_occlusion(baseline_raw), refined)]
    values = [c["net_motion"] for c in baseline if c.get("status")=="made" and _finite(c.get("net_motion"))]
    net_median = median(values) if len(values) >= 8 else None
    repaired = baseline
    repair_events = [[] for _ in inputs]
    if config.track_mode != "off":
        alternate = [_raw_check(item, raw, config.track_mode, fps) for item,raw in zip(inputs,raw_results)]
        repaired = [rc.keep_unless_seen(c,flag) for c,flag in zip(rc.apply_video_occlusion([c for c,_ in alternate]),refined)]
        repair_events = [events for _,events in alternate]
    judged = []
    for item,raw,old,new,events in zip(inputs,raw_results,baseline,repaired,repair_events):
        chosen = old
        hits = []
        notes = []
        if config.track_mode == "fable_stitch":
            if not _finite(fps) or fps <= 0:
                notes.append("stitch_requires_source_fps")
            else:
                chosen = new
        # Changing tracks cannot add a rejection, or directly overrule a seen miss.
        if chosen != old:
            hits.append(config.track_mode)
            if old["status"]!="rejected" and chosen["status"]=="rejected":
                chosen = {**chosen,"status":"unsure","reason":"new_negative_needs_review"}
            elif old["status"]=="rejected" and chosen["status"]!="rejected":
                chosen = {**chosen,"status":"unsure","reason":"conflicting_negative_needs_review"}
        # Do not bypass a conflicting track decision with the visible-crossing rule.
        if chosen == old and config.visible_crossing and _is_visible_crossing(chosen, net_median):
            chosen = {**chosen, "status": "made", "reason": None}
            hits.append("visible_crossing")
        chosen = {**chosen,"experiment":{"config":config.to_dict(),"config_hash":config.config_hash,"baseline_status":old.get("status"),"baseline_reason":old.get("reason"),"final_status":chosen.get("status"),"decision_reason":chosen.get("reason") or "observed_rim_crossing","matched_switches":hits,"notes":notes,"stitches":events,"source_fps":fps,"net_calibration":{"scope":"analysis_run_baseline_made","samples":len(values),"median":net_median}}}
        judged.append(chosen)
    return judged
