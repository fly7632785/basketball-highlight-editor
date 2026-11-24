# Desktop rim rules

The open-source desktop engine enables both L471-approved rules by default:

```json
{"track_mode":"fable_stitch","visible_crossing":true}
```

Set `BHE_RIM_EXPERIMENTS` to a JSON object before starting the application
to override the defaults. Use `{}` to turn off both rules, or supply either
rule by itself to turn off the other. The verification CLI also accepts
`--experiment-config`.

- `track_mode` accepts `off` or `fable_stitch`. Stitching joins unique upper
  and lower falling fragments with a gap greater than 0.4 seconds and at most
  35/30 seconds. It requires source FPS and records the accepted joins.
  A changed track cannot add a rejection or directly promote a rejection to made.
- `visible_crossing` promotes an otherwise unsure, fully observed central
  crossing with a net-bottom exit and no rebound. Both crossing and exit must
  be within a quarter rim width of the center. Net motion must be positive and
  at least 30% of the positive same-run baseline median from at least eight
  made candidates. The rule does not override a conflicting track decision.

Unknown keys and incorrect values fail explicitly. The rim width threshold
stays at 30 pixels. Stitching uses the existing separate FPS-aware detection
cache. Visible crossing rejudges the same detections. Candidate evidence still
records the configuration hash, baseline and final status, matches, and net
calibration. With both rules off, the CLI keeps its pre-conservative-keep status contract.
Use `results[i].experiment.final_status` to compare final statuses.

```sh
python scripts/replay_rim_experiments.py --cache-root /path/to/detections --config '{}' --output /path/to/replay.json
python -m pytest -q
```

Set `BHE_RIM_REPLAY_DATA` to the private frame-cache directory to include the
optional replay in pytest.
