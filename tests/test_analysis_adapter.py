from pathlib import Path
from io import StringIO
import json
import sys
import time
from unittest.mock import Mock

import pytest

from engine.python.basketball_engine.adapters.analysis import (
    PipelineCancelled,
    apply_rim_checks,
    build_pipeline_commands,
    candidate_to_row,
    dedupe_trajectory_matches,
    flatten_coarse_matches,
    flatten_refined_matches,
    scale_roi_to_proxy,
    run_pipeline,
)

from .test_rim_check import RIM, fall, net


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


def test_same_crossing_keeps_earlier_candidate_with_fuller_trajectory():
    crossing = {"time": 10.4, "x": 500, "y": 300}
    points = [{"time": t, "x": 500, "y": y} for t, y in [(10.2, 280), (10.4, 300), (10.6, 320)]]
    matches = [
        {"time": 10.7, "overlay": {"crossing": crossing, "trajectory": points}},
        {"time": 10.2, "confidence": "low", "score": 0, "overlay": {"crossing": crossing, "trajectory": points[:2]}},
    ]
    merged = dedupe_trajectory_matches(matches)
    assert len(merged) == 1 and merged[0]["time"] == 10.2
    assert merged[0]["overlay"]["trajectory"] == points
    assert merged[0]["confidence"] == "low" and merged[0]["score"] == 0


@pytest.mark.parametrize("later_crossing", [None, {"time": 10.5, "x": 500, "y": 300}])
def test_nearby_times_or_missing_tracks_alone_do_not_merge_events(later_crossing):
    matches = [
        {"time": 10.2, "overlay": {"crossing": {"time": 10.4, "x": 500, "y": 300}}},
        {"time": 10.7, "overlay": {"crossing": later_crossing}},
    ]
    assert dedupe_trajectory_matches(matches) == matches


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
    # 快速模式粗扫直出、没有 refine 裁决,不发弱种子。
    assert all(
        "--rim-band-seeds" not in part
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
    # 有精化兜底时,粗扫的筐带单次目击也发弱种子,交给 refine 密扫裁决。
    assert "--rim-band-seeds" in commands[2]


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


def test_run_pipeline_keeps_reading_utf8_and_undecodable_child_output(tmp_path: Path):
    # 中文 Windows 上 ffmpeg 输出的 UTF-8 中文路径曾让读取线程崩掉，
    # 管道写满后 ffmpeg 卡死，界面停在 1%。
    import threading

    refined = tmp_path / "refined.json"
    script = (
        "import json, sys; "
        "sys.stderr.buffer.write(\"from 'C:/视频/篮球赛.mp4':\\n\".encode('utf-8') + b'\\xff\\n'); "
        "sys.stderr.write('x' * 200000); sys.stderr.flush(); "
        "print('progress=0.5', flush=True); "
        "open(%r, 'w', encoding='utf-8').write(json.dumps({'results': []}))"
    ) % str(refined)
    output = []
    finished = {}

    def run():
        finished["result"] = run_pipeline(
            [[sys.executable, "-c", script]],
            refined,
            output_callback=lambda stage, line: output.append(line),
        )

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(20)
    assert "result" in finished, "流水线卡住了"
    assert finished["result"]["refined"] == {"results": []}
    assert "from 'C:/视频/篮球赛.mp4':" in output
    assert "progress=0.5" in output


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


def test_run_pipeline_reports_custom_stage_inside_its_progress_range(tmp_path: Path):
    output = tmp_path / "rim_check.json"
    script = (
        "import json; "
        "print('progress=0.5', flush=True); "
        "open(%r, 'w', encoding='utf-8').write(json.dumps({'results': []}))"
    ) % str(output)
    progress = []
    run_pipeline(
        [[sys.executable, "-c", script]],
        output,
        stage_callback=lambda stage, value: progress.append((stage, round(value, 4))),
        stage_names=("verify_rim_crossing",),
        stage_ranges=((0.80, 0.95),),
    )
    assert progress == [
        ("verify_rim_crossing", 0.8),
        ("verify_rim_crossing", 0.875),
        ("persist_candidates", 0.95),
    ]


def test_rim_checks_drop_occlusion_for_a_video_where_the_net_never_hides_the_ball():
    matches = [{"time": float(index)} for index in range(10)]
    inputs = [{"time": float(index), "rim": RIM} for index in range(10)]
    output = {"results": [
        {"status": "rejected", "frames": fall(hidden={6, 7}) if index < 2 else fall()}
        for index in range(10)
    ]}
    apply_rim_checks(matches, inputs, output)
    assert {match["rim_check"]["status"] for match in matches} == {"made"}
    assert candidate_to_row(
        matches[5], "video-1", "roi-1", 20_000, 0.5, 0.5, "v1"
    )["auto_review_status"] is None


def test_rim_checks_reject_a_still_net_for_a_video_where_the_net_never_hides_the_ball():
    matches = [{"time": float(index)} for index in range(10)]
    inputs = [{"time": float(index), "rim": RIM} for index in range(10)]
    output = {"results": [
        {
            "status": "rejected",
            "frames": [[] for _ in range(30)] + (fall(hidden={6, 7}) if index < 2 else fall()),
            "net_motion_series": net(0.5 if index == 5 else 9.0),
        }
        for index in range(10)
    ]}
    apply_rim_checks(matches, inputs, output)
    assert [match["rim_check"]["reason"] for match in matches].count("net_still") == 1
    assert matches[5]["rim_check"]["reason"] == "net_still"
    assert candidate_to_row(
        matches[5], "video-1", "roi-1", 20_000, 0.5, 0.5, "v1"
    )["auto_review_status"] == "excluded"


def test_rim_checks_keep_unseen_crossings_low_even_without_refine_confirmation():
    matches = [{"time": 0.0}, {"time": 1.0, "coarse_crossing": {"time": 1.0}}]
    inputs = [{"time": match["time"], "rim": RIM} for match in matches]
    output = {"results": [{"status": "rejected", "frames": [[] for _ in range(16)]} for _ in matches]}
    apply_rim_checks(matches, inputs, output)
    assert [(match["rim_check"]["status"], match["rim_check"]["reason"]) for match in matches] == [
        ("unsure", "no_crossing"), ("unsure", "no_crossing"),
    ]
    assert all(match["confidence"] == "low" and match["score"] == 0 for match in matches)
    assert all(match["confidence_reason"] == "rim_check_insufficient_evidence" for match in matches)
    rows = [candidate_to_row(match, "video-1", "roi-1", 20_000, 0.5, 0.5, "v1") for match in matches]
    assert [row["auto_review_status"] for row in rows] == [None, None]


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


def test_pipeline_commands_forward_inference_device(tmp_path: Path):
    """DirectML 只是换推理后端,引擎需要把 device 透传给三个阶段。"""
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
        device="dml",
    )
    for index in (1, 3):
        assert commands[index][commands[index].index("--device") + 1] == "dml"
    # 代理生成与候选生成不吃 device。
    assert "--device" not in commands[0]
    assert "--device" not in commands[2]


def test_rim_check_command_forwards_inference_device(tmp_path: Path):
    from engine.python.basketball_engine.adapters.analysis import build_rim_check_command

    command = build_rim_check_command(
        tmp_path, Path("source.mp4"), Path("model.pt"),
        Path("in.json"), Path("out.json"), device="dml",
    )
    assert command[command.index("--device") + 1] == "dml"


def test_a_long_failure_leads_with_the_real_error_not_a_cut_line(tmp_path: Path):
    # 界面只显示消息第一行；原来从最后 1200 个字符处硬切，第一行常常只剩半个词（“eo”）。
    script = (
        "import sys\n"
        "for i in range(80):\n"
        "    print('processing frame line ' + str(i) + ' of the long running video', file=sys.stderr)\n"
        "print('RuntimeError: example analysis failure', file=sys.stderr)\n"
        "sys.exit(1)\n"
    )
    with pytest.raises(RuntimeError) as error:
        run_pipeline([[sys.executable, "-c", script]], tmp_path / "refined.json")

    lines = str(error.value).splitlines()
    assert lines[0] == "pipeline step 执行失败: RuntimeError: example analysis failure"
    assert "processing frame line" in str(error.value)
    # 保留的日志从整行开始，没有被切断的半行
    assert all(line.startswith("processing frame line") or line.startswith("RuntimeError") for line in lines[1:] if line)


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX signal return codes")
@pytest.mark.parametrize("script_name", ["scan_video.py", "refine_dynamic_candidates.py"])
@pytest.mark.parametrize("cpu_exit", [0, 1, -6, None])
def test_native_inference_crash_retries_cpu_once(tmp_path, capsys, script_name, cpu_exit):
    script = tmp_path / script_name
    attempts = tmp_path / "attempts.jsonl"
    output = tmp_path / "refined.json"
    manifest = tmp_path / "manifest.json"
    script.write_text(
        "import sys, json, os, signal\n"
        f"attempts = {str(attempts)!r}\n"
        "with open(attempts, 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
        "device = sys.argv[sys.argv.index('--device') + 1]\n"
        "if device != 'cpu':\n"
        f"    open({str(output)!r}, 'w').write('{{}}')\n"
        "    print('native mutex failure', file=sys.stderr, flush=True)\n"
        "    os.kill(os.getpid(), signal.SIGABRT)\n"
        "assert '--cache-dir' not in sys.argv\n"
        + (f"open({str(output)!r}, 'w').write('{{\"results\": []}}')\n" if cpu_exit is not None else "")
        + ("os.kill(os.getpid(), signal.SIGABRT)\n" if cpu_exit == -6 else f"sys.exit({cpu_exit or 0})\n"),
        encoding="utf-8",
    )
    command = [sys.executable, str(script), "--device", "auto", "--cache-dir", str(tmp_path / "cache")]
    streamed, processes = [], []
    def execute():
        return run_pipeline([command], output, manifest_path=manifest,
                            stage_outputs=[output], stage_names=["coarse_scan"],
                            output_callback=lambda stage, line: streamed.append(line),
                            process_callback=processes.append)
    if cpu_exit == 0:
        result = execute()
        assert result["refined"] == {"results": []}
        assert any("CPU fallback succeeded" in line for line in result["logs"])
    else:
        with pytest.raises(RuntimeError, match="未生成有效产物" if cpu_exit is None else "执行失败"):
            execute()
    calls = [json.loads(line) for line in attempts.read_text().splitlines()]
    assert len(calls) == 2
    assert calls[0] == command[2:]
    assert calls[1] == ["--device", "cpu"]
    assert command[-2] == "--cache-dir"  # caller's commands remain unchanged
    saved = json.loads(manifest.read_text())["stages"]["coarse_scan"]
    assert saved["state"] == ("completed" if cpu_exit == 0 else "failed")
    assert saved["cpu_fallback"]["exit"] == -6
    assert "native mutex failure" in saved["cpu_fallback"]["diagnostic"]
    assert any("retrying CPU once" in line for line in streamed)
    assert "native exit=-6" in capsys.readouterr().err
    assert len([p for p in processes if p is not None]) == 2
    assert processes[-1] is None


@pytest.mark.parametrize("initial_exit,cpu_exit", [
    (0xC0000005, 0),
    (0xC000001D, 0),
    (0xC0000005, 0xC000001D),
    (1, None),
    (0xC000013A, None),  # Windows console interruption
])
def test_refine_retries_reported_windows_crashes_once(
    tmp_path, monkeypatch, initial_exit, cpu_exit,
):
    output = tmp_path / "refined.json"
    manifest = tmp_path / "manifest.json"
    calls = []

    def start_process(command, **kwargs):
        exit_code = cpu_exit if calls else initial_exit
        assert exit_code is not None
        calls.append(command)
        if exit_code == 0:
            output.write_text('{"results": []}', encoding="utf-8")
        process = Mock(returncode=exit_code, stdout=StringIO(), stderr=StringIO())
        process.poll.return_value = exit_code
        return process

    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.analysis.subprocess.Popen", start_process,
    )
    script = [sys.executable, "refine_dynamic_candidates.py"]
    command = [*script, "--device", "auto", "--cache-dir", str(tmp_path / "cache")]

    def execute():
        return run_pipeline(
            [command], output, manifest_path=manifest, stage_outputs=[output],
            stage_names=["refine_candidates"],
        )

    if cpu_exit == 0:
        assert execute()["refined"] == {"results": []}
    else:
        with pytest.raises(RuntimeError, match="refine_dynamic_candidates.py 执行失败"):
            execute()

    assert calls[0] == command
    saved = json.loads(manifest.read_text())["stages"]["refine_candidates"]
    if cpu_exit is None:
        assert len(calls) == 1
        assert "cpu_fallback" not in saved
    else:
        assert calls[1:] == [[*script, "--device", "cpu"]]
        assert saved["cpu_fallback"]["exit"] == initial_exit
    assert saved["state"] == ("completed" if cpu_exit == 0 else "failed")


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX signal return codes")
@pytest.mark.parametrize("device,exit_code,script_name", [
    ("cpu", -6, "scan_video.py"),
    ("auto", 1, "scan_video.py"),
    ("auto", -6, "other.py"),
])
def test_pipeline_does_not_retry_cpu_or_python_errors_or_other_stages(tmp_path, device, exit_code, script_name):
    script = tmp_path / script_name
    calls = tmp_path / "calls"
    script.write_text(
        f"import os, signal, sys; open({str(calls)!r}, 'a').write('called\\n'); "
        + ("os.kill(os.getpid(), signal.SIGABRT)" if exit_code < 0 else "sys.exit(1)"),
        encoding="utf-8",
    )
    with pytest.raises(RuntimeError, match="执行失败"):
        run_pipeline([[sys.executable, str(script), "--device", device]], tmp_path / "output.json")
    assert calls.read_text() == 'called\n'


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX signal return codes")
def test_native_crash_cancel_before_cpu_retry(tmp_path):
    script = tmp_path / "scan_video.py"
    script.write_text("import os, signal; os.kill(os.getpid(), signal.SIGABRT)", encoding="utf-8")
    cancelled = False
    processes = []

    def on_output(stage, line):
        nonlocal cancelled
        if "retrying CPU once" in line:
            cancelled = True

    with pytest.raises(PipelineCancelled):
        run_pipeline([[sys.executable, str(script), "--device", "auto"]],
                     tmp_path / "output.json", cancel_check=lambda: cancelled,
                     output_callback=on_output, process_callback=processes.append)
    assert len([p for p in processes if p is not None]) == 1
    assert processes[-1] is None
