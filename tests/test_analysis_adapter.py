from pathlib import Path
import json
import sys
import time

import pytest

from engine.python.basketball_engine.adapters.analysis import (
    PipelineCancelled,
    build_pipeline_commands,
    candidate_to_row,
    flatten_coarse_matches,
    flatten_refined_matches,
    scale_roi_to_proxy,
    run_pipeline,
)


def test_scale_roi_to_proxy_preserves_relative_coordinates():
    assert scale_roi_to_proxy({"x1": 100, "y1": 200, "x2": 500, "y2": 800}, 1920, 960) == [50, 100, 250, 400]


def test_scale_roi_to_proxy_uses_fit_scale_for_non_matching_aspect_ratio():
    assert scale_roi_to_proxy(
        {"x1": 100, "y1": 200, "x2": 500, "y2": 800},
        1080,
        960,
        source_height=1920,
        proxy_height=720,
    ) == [38, 75, 188, 300]


def test_flatten_refined_matches_deduplicates_by_event_time():
    data = {
        "results": [
            {"refined": [{"time": 10.0, "score": 0.4}, {"time": 20.0, "score": 0.5}]},
            {"refined": [{"time": 10.8, "score": 0.8}]},
        ]
    }
    matches = flatten_refined_matches(data, dedupe_seconds=2.0)
    assert [match["time"] for match in matches] == [10.8, 20.0]


def test_flatten_refined_matches_prefers_made_over_higher_score_ambiguous():
    matches = flatten_refined_matches({
        "results": [{
            "refined": [
                {"time": 1.0, "score": 0.6, "verdict": "made"},
                {"time": 1.5, "score": 0.95, "verdict": "ambiguous"},
            ],
        }],
    })

    assert matches == [{"time": 1.0, "score": 0.6, "verdict": "made"}]


def test_flatten_coarse_matches_deduplicates_candidate_events():
    matches = flatten_coarse_matches({
        "candidates": [
            {"time": 10.0, "score": 0.4},
            {"time": 10.8, "score": 0.8},
            {"time": 20.0, "score": 0.5},
        ],
    })

    assert [match["time"] for match in matches] == [10.8, 20.0]


def test_pipeline_commands_can_skip_refinement_for_fast_mode(tmp_path: Path):
    commands = build_pipeline_commands(
        repo_root=tmp_path,
        source_video=Path("source.mp4"),
        proxy_video=Path("proxy.mp4"),
        model_path=Path("model.pt"),
        coarse_detections=Path("coarse.json"),
        coarse_candidates=Path("candidates.json"),
        refined_output=Path("refined.json"),
        proxy_roi=[10, 20, 100, 200],
        source_roi=[20, 40, 200, 400],
        cache_dir=Path("cache"),
        include_refinement=False,
    )

    assert len(commands) == 3
    assert all(
        "refine_dynamic_candidates.py" not in part
        for command in commands
        for part in command
    )


def test_pipeline_commands_use_existing_scripts(tmp_path: Path):
    commands = build_pipeline_commands(
        repo_root=tmp_path,
        source_video=Path("source.mp4"),
        proxy_video=Path("proxy.mp4"),
        model_path=Path("model.pt"),
        coarse_detections=Path("coarse.json"),
        coarse_candidates=Path("candidates.json"),
        refined_output=Path("refined.json"),
        proxy_roi=[10, 20, 100, 200],
        source_roi=[20, 40, 200, 400],
        cache_dir=Path("cache"),
    )
    assert commands[0][1].endswith("create_proxy.py")
    assert commands[1][1].endswith("scan_video.py")
    assert commands[2][1].endswith("generate_candidates.py")
    assert commands[3][1].endswith("refine_dynamic_candidates.py")


def test_pipeline_commands_normalize_float_roi_arguments(tmp_path: Path):
    commands = build_pipeline_commands(
        repo_root=tmp_path,
        source_video=Path("source.mp4"),
        proxy_video=Path("proxy.mp4"),
        model_path=Path("model.pt"),
        coarse_detections=Path("coarse.json"),
        coarse_candidates=Path("candidates.json"),
        refined_output=Path("refined.json"),
        proxy_roi=[10.0, 20.0, 100.0, 200.0],
        source_roi=[20.0, 40.0, 200.0, 400.0],
        cache_dir=Path("cache"),
    )
    assert commands[3][commands[3].index("--roi") + 1:commands[3].index("--proxy-scale")] == ["20", "40", "200", "400"]


def test_pipeline_commands_forward_refine_window(tmp_path: Path):
    commands = build_pipeline_commands(
        repo_root=tmp_path,
        source_video=Path("source.mp4"),
        proxy_video=Path("proxy.mp4"),
        model_path=Path("model.pt"),
        coarse_detections=Path("coarse.json"),
        coarse_candidates=Path("candidates.json"),
        refined_output=Path("refined.json"),
        proxy_roi=[10, 20, 100, 200],
        source_roi=[20, 40, 200, 400],
        cache_dir=Path("cache"),
        window_seconds=4.0,
    )
    assert commands[3][commands[3].index("--window") + 1] == "4.0"


def test_pipeline_commands_limit_proxy_and_preserve_source_timestamps(tmp_path: Path):
    commands = build_pipeline_commands(
        repo_root=tmp_path,
        source_video=Path("source.mp4"),
        proxy_video=Path("proxy.mp4"),
        model_path=Path("model.pt"),
        coarse_detections=Path("coarse.json"),
        coarse_candidates=Path("candidates.json"),
        refined_output=Path("refined.json"),
        proxy_roi=[10, 20, 100, 200],
        source_roi=[20, 40, 200, 400],
        cache_dir=Path("cache"),
        analysis_start_ms=120_000,
        analysis_end_ms=300_000,
        net_roi=[40, 100, 180, 340],
    )
    assert commands[0][commands[0].index("--start-time") + 1] == "120.0"
    assert commands[0][commands[0].index("--duration") + 1] == "180.0"
    assert commands[1][commands[1].index("--time-offset") + 1] == "120.0"
    assert commands[3][commands[3].index("--net-roi") + 1:commands[3].index("--output")] == ["40", "100", "180", "340"]


def test_pipeline_proxy_preserves_source_aspect_ratio(tmp_path: Path):
    script = Path(__file__).parents[1] / "scripts" / "create_proxy.py"
    assert "force_original_aspect_ratio=decrease" in script.read_text(encoding="utf-8")


def test_candidate_to_row_creates_reviewable_clip_window():
    row = candidate_to_row(
        {"time": 12.5, "score": 0.82, "confidence": "high", "gates": {"review": True}},
        video_id="video-1",
        roi_id="roi-1",
        duration_ms=30_000,
        before_seconds=6,
        after_seconds=3,
        detector_version="python-v1",
    )
    assert row["event_time_ms"] == 12_500
    assert row["review_start_ms"] == 6_500
    assert row["review_end_ms"] == 15_500
    assert row["video_id"] == "video-1"


def test_candidate_to_row_embeds_conservative_review_reason_suggestion():
    row = candidate_to_row(
        {
            "time": 12.5,
            "score": 0.4,
            "confidence": "review",
            "rebound": True,
        },
        video_id="video-1",
        roi_id="roi-1",
        duration_ms=30_000,
        before_seconds=6,
        after_seconds=3,
        detector_version="python-v1",
    )

    evidence = json.loads(row["evidence_json"])
    assert evidence["review_reason_suggestion"]["primary"] == "rebound"
    assert evidence["review_reason_suggestion"]["confidence"] == "high"


def test_candidate_to_row_records_analysis_source_in_evidence():
    row = candidate_to_row(
        {"time": 2.5, "score": 0.7},
        video_id="video-1",
        roi_id="roi-1",
        duration_ms=10_000,
        before_seconds=1,
        after_seconds=1,
        detector_version="python-v1:fast",
        analysis_source="coarse",
    )

    evidence = json.loads(row["evidence_json"])
    assert evidence["analysis_source"] == "coarse"


def test_run_pipeline_executes_commands_and_reads_refined_output(tmp_path: Path):
    refined = tmp_path / "refined.json"
    script = "from pathlib import Path; Path({!r}).write_text({!r}, encoding='utf-8')".format(
        str(refined), json.dumps({"results": []})
    )
    stages = []
    result = run_pipeline([[sys.executable, "-c", script]], refined, lambda stage, _: stages.append(stage))
    assert result["refined"] == {"results": []}
    assert stages == ["prepare_proxy", "persist_candidates"]
    assert result["stage_timings_ms"]["prepare_proxy"] >= 0


def test_run_pipeline_honors_cancellation_before_start(tmp_path: Path):
    refined = tmp_path / "refined.json"
    with pytest.raises(PipelineCancelled, match="JOB_CANCELLED"):
        run_pipeline([[sys.executable, "-c", "raise SystemExit(1)"]], refined, cancel_check=lambda: True)


def test_run_pipeline_surfaces_stderr_for_failed_step(tmp_path: Path):
    refined = tmp_path / "refined.json"
    with pytest.raises(RuntimeError, match="pipeline step 执行失败: boom"):
        run_pipeline(
            [[sys.executable, "-c", "import sys; print('boom', file=sys.stderr); sys.exit(1)"]],
            refined,
        )


def test_run_pipeline_terminates_running_step_when_cancelled(tmp_path: Path):
    refined = tmp_path / "refined.json"
    started = time.monotonic()
    with pytest.raises(PipelineCancelled, match="JOB_CANCELLED"):
        run_pipeline(
            [[sys.executable, "-c", "import time; time.sleep(30)"]],
            refined,
            cancel_check=lambda: time.monotonic() - started > 0.15,
        )
    assert time.monotonic() - started < 3


def test_run_pipeline_drains_large_child_output_without_deadlocking(tmp_path: Path):
    refined = tmp_path / "refined.json"
    script = (
        "import json, sys; "
        "sys.stderr.write('x' * 200000); sys.stderr.flush(); "
        "open(%r, 'w', encoding='utf-8').write(json.dumps({'results': []}))"
    ) % str(refined)
    result = run_pipeline([[sys.executable, "-c", script]], refined)
    assert result["refined"] == {"results": []}
    assert result["logs"]


def test_run_pipeline_streams_child_output_to_progress_callback(tmp_path: Path):
    refined = tmp_path / "refined.json"
    script = (
        "import json, time; "
        "print('progress=0.25', flush=True); "
        "time.sleep(0.02); "
        "open(%r, 'w', encoding='utf-8').write(json.dumps({'results': []}))"
    ) % str(refined)
    output = []
    progress = []
    result = run_pipeline(
        [[sys.executable, "-c", script]],
        refined,
        stage_callback=lambda stage, value: progress.append((stage, value)),
        output_callback=lambda stage, line: output.append((stage, line)),
    )
    assert result["refined"] == {"results": []}
    assert ("prepare_proxy", "progress=0.25") in output
    assert ("prepare_proxy", 0.245) in progress


def test_run_pipeline_reuses_completed_manifest_stage(tmp_path: Path):
    refined = tmp_path / "refined.json"
    proxy = tmp_path / "proxy.mp4"
    manifest = tmp_path / "manifest.json"
    proxy.write_bytes(b"proxy")
    refined.write_text(json.dumps({"results": []}), encoding="utf-8")
    manifest.write_text(
        json.dumps({
            "version": 1,
            "stages": {
                "prepare_proxy": {
                    "state": "completed",
                    "output": str(proxy),
                },
            },
        }),
        encoding="utf-8",
    )
    script = "raise SystemExit('stage should have been reused')"
    result = run_pipeline(
        [[sys.executable, "-c", script]],
        refined,
        manifest_path=manifest,
        stage_outputs=[proxy],
    )
    assert result["cache_hits"] == 1
    assert "reused" in result["logs"][0]


def test_run_pipeline_ignores_manifest_from_another_algorithm_version(tmp_path: Path):
    refined = tmp_path / "refined.json"
    proxy = tmp_path / "proxy.mp4"
    manifest = tmp_path / "manifest.json"
    proxy.write_bytes(b"proxy")
    manifest.write_text(
        json.dumps({
            "version": "old-algorithm",
            "stages": {
                "prepare_proxy": {
                    "state": "completed",
                    "output": str(proxy),
                },
            },
        }),
        encoding="utf-8",
    )
    script = "from pathlib import Path; Path({!r}).write_text({!r}, encoding='utf-8')".format(
        str(refined), json.dumps({"results": []})
    )

    result = run_pipeline(
        [[sys.executable, "-c", script]],
        refined,
        manifest_path=manifest,
        manifest_version="new-algorithm",
        stage_outputs=[proxy],
    )

    assert result["cache_hits"] == 0
    assert result["refined"] == {"results": []}
