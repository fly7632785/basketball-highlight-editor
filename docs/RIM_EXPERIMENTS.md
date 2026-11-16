# Desktop rim experiments (algo/tier-1)

Experimental Python desktop code only. All switches are off by default. Do not
use these experiments as evidence that a candidate is a guaranteed goal.

Set `BHE_RIM_EXPERIMENTS` to one JSON object **before starting the desktop app or
engine**. Alternatively, pass `--experiment-config '<JSON>'` to
`scripts/verify_rim_crossing.py`. Explicit CLI configuration overrides the environment.
Unknown keys, wrong types and non-finite/out-of-range parameters fail explicitly.

```json
{
  "min_rim_width_px": 30,
  "track_mode": "off",
  "net_weak": false,
  "net_weak_ratio": 0.3,
  "net_min_samples": 8,
  "supported_side_exit": false
}
```

Try each independently: `{"min_rim_width_px":24}`,
`{"track_mode":"fable_stitch"}`, `{"track_mode":"astra_fill"}`,
`{"net_weak":true}`, `{"supported_side_exit":true}`. Omitted keys keep defaults.

- Small rims: lowering the threshold schedules actual source-frame detection.
  Existing skipped caches cannot supply missing frames or prove the change works.
- Fable stitch: uniquely matched upper/lower falling fragments, gap >0.4 and
  <=35/30 seconds, with the proposed rim corridors. Competing matches are not
  joined. The source FPS must be known; gap frames/seconds and source tracks are
  recorded. Historical caches without FPS require a new detection pass; the
  service uses a separate cache key for this first FPS-aware experiment.
- Astra fill: use consecutive (not accumulated) six-frame static filtering,
  but accept the repair only for a baseline `unsure/no_entry` or `unsure/no_exit`
  crossing that becomes `made` within 0.12 rim widths and one crossing frame.
- Track changes cannot add a rejection or directly promote an original rejection
  to `made`: a conflicting result becomes `unsure`.
- Weak net motion: calibrate on **baseline made candidates of this analysis run**,
  not labels or repaired results. At least eight finite samples and a positive
  median are required. A made candidate below 0.3 of that median becomes `unsure`;
  a missing measurement is separately recorded as `net_missing`. Neither excludes.
- Supported side exit: `exit_off_center` requires >=10 points and >=1 rim-width
  span. Otherwise it becomes `unsure`, including the short off-center fallback.
  Independent observed rebound evidence still rejects.

Final engine `rim_check.experiment` includes normalized configuration, full SHA256
`config_hash`, baseline/final status and reason, matched switches, calibration
scope/count/median, FPS, and accepted joins. This metadata is also stored in the
candidate evidence JSON. Reasons such as `net_weak`, `net_missing` and
`short_side_exit_track` are machine-readable; existing generic review wording is
unchanged. No mobile code is changed.

Detection-cache identity changes for the small-rim threshold and for acquiring
FPS for Fable stitching. Other switches reuse raw detections and are always
rejudged under the current configuration hash; old cached decision metadata is
not trusted. Default detection keys are unchanged. Each subprocess receives a
snapshot of the parent's parsed configuration.

The standalone detection script historically returns pre-conservative-keep
statuses. With default configuration these remain unchanged; the final status is
in `results[i].experiment.final_status`. Enabled experiments also publish final
statuses in `results[i].status`. Compare the metadata final status in **all** runs.

Offline default regression (requires the private cache package and git baseline):

```sh
python scripts/replay_rim_experiments.py --cache-root /path/to/detections --config '{}' --output /path/to/replay.json
python -m pytest -q
```

Replay compares every decision field against `git show cb8de11:src/basketball_highlight/rim_check.py`,
ignoring only new experiment metadata; default differences cause nonzero exit.
Private data is not shipped in this repository. Set `BHE_RIM_REPLAY_DATA` to the
cache directory to include the replay as a pytest test. Experimental replay
reports changes but cannot recover detections skipped by the old configuration.
