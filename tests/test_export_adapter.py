import io
from pathlib import Path
import shutil
import subprocess

import pytest

from engine.python.basketball_engine.adapters.analysis import PipelineCancelled
from engine.python.basketball_engine.adapters.export import build_clip_command, run_atomic_ffmpeg
from engine.python.basketball_engine.adapters import export


def test_libx264_clip_command_contains_one_video_codec():
    command = build_clip_command(Path("source.mp4"), 0, 1000, Path("out.mp4"), "libx264")
    assert command.count("-c:v") == 1
    assert command[command.index("-c:v") + 1] == "libx264"


def test_clip_file_name_appends_a_filesystem_safe_player_name():
    candidate = {"event_time_ms": 12345}
    assert export.clip_file_name(1, candidate) == "goal_001_12.35s.mp4"
    assert export.clip_file_name(2, {**candidate, "player_name": "科比"}) == "goal_002_12.35s_科比.mp4"
    assert export.clip_file_name(3, {**candidate, "player_name": ' A/B:C*? '}) == "goal_003_12.35s_A_B_C.mp4"
    assert export.clip_file_name(4, {**candidate, "player_name": "..."}) == "goal_004_12.35s.mp4"


def test_clip_command_maps_only_the_first_audio_stream():
    command = build_clip_command(Path("source.mov"), 0, 1000, Path("out.mp4"), "libx264")
    maps = [command[index + 1] for index, item in enumerate(command) if item == "-map"]
    assert maps == ["0:v:0?", "0:a:0?"]


def test_clip_command_rejects_invalid_range():
    with pytest.raises(ValueError, match="INVALID_CLIP_RANGE"):
        build_clip_command(Path("source.mp4"), 1000, 1000, Path("out.mp4"))


@pytest.mark.parametrize("mode", ["separate", "merge"])
def test_export_without_h264_encoders_falls_back_for_clips_and_merge(tmp_path, monkeypatch, mode):
    monkeypatch.setattr(export.platform, "system", lambda: "Linux")
    attempts = []

    def fake_ffmpeg(command, output_path, **kwargs):
        if "-c:v" not in command:
            attempts.append("copy")
            raise subprocess.CalledProcessError(1, command)
        codec = command[command.index("-c:v") + 1]
        attempts.append(codec)
        if codec != "mpeg4":
            raise subprocess.CalledProcessError(1, command)
        assert command[command.index("-q:v") + 1] == "2"
        output_path.write_bytes(b"video")

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fake_ffmpeg)
    result = export.export_goal_clips(
        [{"source_path": str(tmp_path / "source.mp4"), "event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000}],
        tmp_path / "export", mode,
    )
    expected = ["libx264", "libopenh264", "mpeg4"]
    if mode == "merge":
        expected += ["copy", "mpeg4"]
    assert attempts == expected
    assert all(Path(path).is_file() for path in result["files"])


def test_codec_order_per_platform(monkeypatch):
    software = ["libx264", "libopenh264", "mpeg4"]
    monkeypatch.setattr(export.platform, "system", lambda: "Darwin")
    assert export.video_codecs() == ["h264_videotoolbox", *software]
    monkeypatch.setattr(export.platform, "system", lambda: "Windows")
    assert export.video_codecs() == ["h264_nvenc", "h264_qsv", "h264_amf", "h264_mf", *software]


def test_hardware_encoders_get_a_bitrate():
    options = export.video_codec_options("h264_nvenc")
    assert options[options.index("-b:v") + 1] == "16M"


@pytest.mark.parametrize("mode", ["separate", "merge"])
def test_windows_tries_gpu_encoders_and_keeps_the_one_that_works(tmp_path, monkeypatch, mode):
    monkeypatch.setattr(export.platform, "system", lambda: "Windows")
    # The fake clip bytes below cannot be probed; this test exercises codec fallback.
    monkeypatch.setattr(export, "_compatible_color_streams", lambda paths: True)
    attempts = []

    def fake_ffmpeg(command, output_path, **kwargs):
        if "-c:v" not in command:
            attempts.append("copy")
            raise subprocess.CalledProcessError(1, command)
        codec = command[command.index("-c:v") + 1]
        attempts.append(codec)
        if codec in {"h264_nvenc", "h264_qsv"}:
            raise subprocess.CalledProcessError(1, command)
        output_path.write_bytes(b"video")

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fake_ffmpeg)
    export.export_goal_clips(
        [
            {"source_path": str(tmp_path / "source.mp4"), "event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000},
            {"source_path": str(tmp_path / "source.mp4"), "event_time_ms": 2500, "review_start_ms": 2000, "review_end_ms": 3000},
        ],
        tmp_path / "export", mode,
    )
    expected = ["h264_nvenc", "h264_qsv", "h264_amf", "h264_amf"]
    if mode == "merge":
        expected += ["copy", "h264_amf"]
    assert attempts == expected


def test_export_does_not_retry_cancelled_encoding(tmp_path, monkeypatch):
    attempts = []

    def cancel(command, output_path, **kwargs):
        attempts.append(command)
        raise PipelineCancelled("JOB_CANCELLED")

    monkeypatch.setattr(export, "run_atomic_ffmpeg", cancel)
    with pytest.raises(PipelineCancelled):
        export.export_goal_clips(
            [{"source_path": str(tmp_path / "source.mp4"), "event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000}],
            tmp_path / "export", "separate",
        )
    assert len(attempts) == 1


def test_export_surfaces_error_when_all_encoders_fail(tmp_path, monkeypatch):
    monkeypatch.setattr(export.platform, "system", lambda: "Linux")
    attempts = []

    def fail(command, output_path, **kwargs):
        attempts.append(command[command.index("-c:v") + 1])
        raise subprocess.CalledProcessError(1, command)

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fail)
    with pytest.raises(subprocess.CalledProcessError):
        export.export_goal_clips(
            [{"source_path": str(tmp_path / "source.mp4"), "event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000}],
            tmp_path / "export", "separate",
        )
    assert attempts == ["libx264", "libopenh264", "mpeg4"]
    assert not list((tmp_path / "export").glob("*.mp4"))


def test_run_atomic_ffmpeg_validates_and_renames_output(tmp_path: Path, monkeypatch):
    output = tmp_path / "clip.mp4"

    class FakeProcess:
        returncode = 0

        def __init__(self, command, **_kwargs):
            Path(command[-1]).write_bytes(b"video")

        def poll(self):
            return self.returncode

    def fake_run(command, **_kwargs):
        return type("Completed", (), {"stdout": "1.25\n"})()

    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.subprocess.Popen",
        FakeProcess,
    )
    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.subprocess.run",
        fake_run,
    )
    run_atomic_ffmpeg(["ffmpeg", "-y", "-i", "source.mp4", str(output)], output)
    assert output.read_bytes() == b"video"
    assert not list(tmp_path.glob("*.part*"))


def test_run_atomic_ffmpeg_removes_partial_output_on_failure(tmp_path: Path, monkeypatch):
    output = tmp_path / "clip.mp4"

    class FakeProcess:
        returncode = 1

        def __init__(self, command, **_kwargs):
            Path(command[-1]).write_bytes(b"partial")

        def poll(self):
            return self.returncode

    import subprocess
    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.subprocess.Popen",
        FakeProcess,
    )
    with pytest.raises(subprocess.CalledProcessError):
        run_atomic_ffmpeg(["ffmpeg", "-y", str(output)], output)
    assert not output.exists()
    assert not list(tmp_path.glob("*.part*"))


def test_run_atomic_ffmpeg_keeps_stderr_tail_in_error(tmp_path: Path, monkeypatch):
    output = tmp_path / "clip.mp4"
    stderr_text = (
        "[aist#0:2/none @ 0x1] Decoding requested, but no decoder found for: none\n"
        "Error opening output files: Invalid argument\n"
    )

    class FakeProcess:
        returncode = 234

        def __init__(self, command, **_kwargs):
            Path(command[-1]).write_bytes(b"partial")
            self.stderr = io.StringIO(stderr_text)

        def poll(self):
            return self.returncode

    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.subprocess.Popen",
        FakeProcess,
    )
    with pytest.raises(subprocess.CalledProcessError) as error:
        run_atomic_ffmpeg(["ffmpeg", "-y", str(output)], output)
    message = str(error.value)
    assert message.startswith("ffmpeg 退出码 234: ")
    assert str(output.parent) not in message
    assert "no decoder found for: none" in message
    assert "Invalid argument" in message
    assert not output.exists()
    assert not list(tmp_path.glob("*.part*"))


def test_run_atomic_ffmpeg_stops_running_process_when_cancelled(tmp_path: Path, monkeypatch):
    output = tmp_path / "clip.mp4"
    processes = []

    class FakeProcess:
        returncode = None

        def __init__(self, command, **_kwargs):
            self.command = command

        def poll(self):
            return self.returncode

    def fake_popen(command, **kwargs):
        process = FakeProcess(command, **kwargs)
        processes.append(process)
        return process

    def fake_terminate(process):
        process.returncode = -15

    callbacks = []
    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.subprocess.Popen",
        fake_popen,
    )
    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.terminate_process",
        fake_terminate,
    )

    with pytest.raises(PipelineCancelled, match="JOB_CANCELLED"):
        run_atomic_ffmpeg(
            ["ffmpeg", "-y", str(output)],
            output,
            cancel_check=lambda: True,
            process_callback=callbacks.append,
        )

    assert processes[0].returncode == -15
    assert callbacks == [processes[0], None]
    assert not output.exists()


def _ffmpeg_or_skip():
    from engine.python.basketball_engine.media_tools import resolve_media_tool

    ffmpeg = resolve_media_tool("ffmpeg")
    ffprobe = resolve_media_tool("ffprobe")
    if not shutil.which(ffmpeg) or not shutil.which(ffprobe):
        pytest.skip("需要 ffmpeg/ffprobe")
    return ffmpeg, ffprobe


def test_export_keeps_only_the_first_audio_track(tmp_path: Path):
    # iPhone 视频除了 AAC 还带一条 FFmpeg 解不了的空间音频轨，全部映射会让导出失败。
    ffmpeg, ffprobe = _ffmpeg_or_skip()
    source = tmp_path / "two_audio.mp4"
    subprocess.run(
        [
            ffmpeg, "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440",
            "-f", "lavfi", "-i", "sine=frequency=880",
            "-map", "0", "-map", "1", "-map", "2", "-t", "2",
            "-c:v", "mpeg4", "-c:a", "aac", str(source),
        ],
        check=True,
    )
    result = export.export_goal_clips(
        [{"source_path": str(source), "event_time_ms": 1000, "review_start_ms": 0, "review_end_ms": 1500}],
        tmp_path / "out",
        "separate",
    )
    streams = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", result["files"][0]],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    assert streams.count("audio") == 1
    assert streams.count("video") == 1


def test_run_atomic_ffmpeg_failure_message_includes_ffmpeg_reason(tmp_path: Path):
    ffmpeg, _ = _ffmpeg_or_skip()
    output = tmp_path / "clip.mp4"
    with pytest.raises(subprocess.CalledProcessError) as error:
        run_atomic_ffmpeg(
            [ffmpeg, "-y", "-v", "error", "-i", str(tmp_path / "missing.mp4"), str(output)],
            output,
        )
    assert "missing.mp4" in str(error.value)
    assert "ffmpeg 退出码" in str(error.value)


def test_merge_across_sources_scales_to_the_first_clip_and_names_segments(tmp_path: Path):
    ffmpeg, ffprobe = _ffmpeg_or_skip()
    sources = []
    for name, size in (("first.mp4", "320x240"), ("second.mp4", "640x360")):
        source = tmp_path / name
        subprocess.run(
            [
                ffmpeg, "-v", "error", "-y",
                "-f", "lavfi", "-i", f"testsrc=size={size}:rate=30",
                "-f", "lavfi", "-i", "sine=frequency=440",
                "-t", "2", "-c:v", "mpeg4", "-c:a", "aac", str(source),
            ],
            check=True,
        )
        sources.append((source, *map(int, size.split("x"))))
    candidates = [
        {
            "source_path": str(source), "width": width, "height": height, "segment": segment,
            "event_time_ms": 1000, "review_start_ms": 0, "review_end_ms": 1500,
        }
        for segment, (source, width, height) in enumerate(sources, 1)
    ]
    result = export.export_goal_clips(candidates, tmp_path / "out", "merge")
    assert [Path(path).name for path in result["clip_files"]] == [
        "goal_001_s1_1.00s.mp4",
        "goal_002_s2_1.00s.mp4",
    ]
    for path in result["clip_files"] + result["files"]:
        size = subprocess.run(
            [ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", path],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        assert size == "320,240"


# --- issue #8：输出路径不可推断封装格式导致导出必然失败 -------------------------


def test_atomic_ffmpeg_keeps_media_extension_and_declares_container(tmp_path: Path, monkeypatch):
    output = tmp_path / "clip.mp4"
    commands = []

    class FakeProcess:
        returncode = 0

        def __init__(self, command, **_kwargs):
            commands.append(command)
            Path(command[-1]).write_bytes(b"video")

        def poll(self):
            return self.returncode

    monkeypatch.setattr(export.subprocess, "Popen", FakeProcess)
    monkeypatch.setattr(
        export.subprocess, "run",
        lambda *args, **kwargs: type("Completed", (), {"stdout": "1.25\n"})(),
    )
    run_atomic_ffmpeg(["ffmpeg", "-y", "-i", "source.mp4", str(output)], output)
    temporary = Path(commands[0][-1])
    assert temporary.name.endswith(".part.mp4")
    assert commands[0][-3:-1] == ["-f", "mp4"]
    assert output.read_bytes() == b"video"


@pytest.mark.parametrize(
    "name",
    ["BHE.highlights-261003", "highlights-261003", "导出"],
)
def test_atomic_ffmpeg_never_ends_the_temp_name_with_part(tmp_path: Path, monkeypatch, name):
    output = tmp_path / name
    commands = []

    class FakeProcess:
        returncode = 0

        def __init__(self, command, **_kwargs):
            commands.append(command)
            Path(command[-1]).write_bytes(b"video")

        def poll(self):
            return self.returncode

    monkeypatch.setattr(export.subprocess, "Popen", FakeProcess)
    monkeypatch.setattr(
        export.subprocess, "run",
        lambda *args, **kwargs: type("Completed", (), {"stdout": "1.25\n"})(),
    )
    run_atomic_ffmpeg(["ffmpeg", "-y", "-i", "source.mp4", str(output)], output)
    assert Path(commands[0][-1]).suffix == ".mp4"
    assert commands[0][-3:-1] == ["-f", "mp4"]


def test_output_path_gains_mp4_without_losing_dots_in_the_name():
    assert export.normalize_output_path(Path("BHE.highlights-261003")) == Path(
        "BHE.highlights-261003.mp4"
    )
    assert export.normalize_output_path(Path("highlights")) == Path("highlights.mp4")
    assert export.normalize_output_path(Path("clip.MP4")) == Path("clip.MP4")


def test_validate_output_file_reports_unwritable_location(tmp_path: Path, monkeypatch):
    def deny(**kwargs):
        raise PermissionError(13, "Permission denied")

    monkeypatch.setattr(export.tempfile, "mkstemp", deny)
    with pytest.raises(OSError, match="导出位置不可用"):
        export.validate_output_file(tmp_path / "clip.mp4")


def test_validate_output_file_rejects_a_directory_target(tmp_path: Path):
    with pytest.raises(OSError, match="导出目标是文件夹"):
        export.validate_output_file(tmp_path)


def test_merge_writes_mp4_when_the_saved_name_has_no_extension(tmp_path: Path, monkeypatch):
    def fake_ffmpeg(command, output_path, **kwargs):
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(b"video")

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fake_ffmpeg)
    result = export.export_goal_clips(
        [{"source_path": str(tmp_path / "source.mp4"), "event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000}],
        tmp_path / "export", "merge", tmp_path / "BHE.highlights-261003",
    )
    assert Path(result["files"][0]).name == "BHE.highlights-261003.mp4"


def test_encoder_fallback_does_not_retry_a_muxer_failure(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(export.platform, "system", lambda: "Linux")
    attempts = []

    def fail(command, output_path, **kwargs):
        attempts.append(command[command.index("-c:v") + 1])
        raise export.MediaCommandError(
            234, command,
            "Unable to choose an output format for 'x.part'; use a standard extension",
        )

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fail)
    with pytest.raises(export.MediaCommandError):
        export.export_goal_clips(
            [{"source_path": str(tmp_path / "source.mp4"), "event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000}],
            tmp_path / "export", "separate",
        )
    assert attempts == ["libx264"]


def test_encoder_fallback_still_switches_encoder_on_encoder_failures(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(export.platform, "system", lambda: "Linux")
    attempts = []

    def fake(command, output_path, **kwargs):
        codec = command[command.index("-c:v") + 1]
        attempts.append(codec)
        if codec != "mpeg4":
            raise export.MediaCommandError(1, command, "Unknown encoder 'x'")
        output_path.write_bytes(b"video")

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fake)
    export.export_goal_clips(
        [{"source_path": str(tmp_path / "source.mp4"), "event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000}],
        tmp_path / "export", "separate",
    )
    assert attempts == ["libx264", "libopenh264", "mpeg4"]


def test_encoder_fallback_continues_past_an_encoder_missing_from_the_ffmpeg_build(tmp_path: Path, monkeypatch):
    # Windows 随包的 LGPL FFmpeg 没有 libx264；FFmpeg 8 的原话会带上 "Error opening output file"。
    monkeypatch.setattr(export.platform, "system", lambda: "Linux")
    attempts = []

    def fake(command, output_path, **kwargs):
        codec = command[command.index("-c:v") + 1]
        attempts.append(codec)
        if codec == "libx264":
            raise export.MediaCommandError(
                4294967288, command,
                "[vost#0:0 @ 0x1] Unknown encoder 'libx264'\n"
                "[vost#0:0 @ 0x1] Error selecting an encoder\n"
                "Error opening output file x.part.mp4.\n"
                "Error opening output files: Encoder not found",
            )
        output_path.write_bytes(b"video")

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fake)
    export.export_goal_clips(
        [{"source_path": str(tmp_path / "source.mp4"), "event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000}],
        tmp_path / "export", "separate",
    )
    assert attempts == ["libx264", "libopenh264"]


def test_media_command_error_prints_a_signed_windows_exit_code():
    message = str(export.MediaCommandError(4294967274, ["ffmpeg"], "Invalid argument"))
    assert "-22" in message
    assert "4294967274" not in message


def _fps_source(tmp_path: Path, name: str, rate: str, timescale: int) -> Path:
    ffmpeg, _ = _ffmpeg_or_skip()
    source = tmp_path / f"{name}.mp4"
    subprocess.run(
        [
            ffmpeg, "-v", "error", "-y",
            "-f", "lavfi", "-i", f"testsrc=size=640x360:rate={rate}",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-video_track_timescale", str(timescale), "-c:a", "aac", str(source),
        ],
        check=True,
    )
    return source


def _stream_durations(path: str) -> dict[str, float]:
    _, ffprobe = _ffmpeg_or_skip()
    rows = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries", "stream=codec_type,duration", "-of", "csv=p=0", path],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    return {row.split(",")[0]: float(row.split(",")[1]) for row in rows}


def _mixed_rate_candidates(tmp_path: Path, with_fps: bool):
    sources = [
        (_fps_source(tmp_path, "s60a", "60", 600), 60.0),
        (_fps_source(tmp_path, "s60b", "60", 600), 60.0),
        (_fps_source(tmp_path, "s5994", "60000/1001", 60000), 59.94),
    ]
    return [
        {
            "source_path": str(source), "event_time_ms": 600, "review_start_ms": 100, "review_end_ms": 1100,
            "width": 640, "height": 360, "has_audio": True, **({"fps": fps} if with_fps else {}),
        }
        for source, fps in sources
    ]


@pytest.mark.parametrize("with_fps", [True, False])
def test_merge_of_mixed_frame_rates_keeps_the_summed_duration(tmp_path: Path, with_fps):
    # 60 + 60 + 59.94 帧各 1 秒：成品必须约 3 秒，不能被拉长（用户反馈 3 秒变 11.75 秒）。
    candidates = _mixed_rate_candidates(tmp_path, with_fps)
    result = export.export_goal_clips(
        candidates, tmp_path / "out", "merge", output_path=tmp_path / "out" / "final.mp4",
    )
    durations = _stream_durations(result["files"][0])
    assert durations["video"] == pytest.approx(3.0, abs=0.1)
    assert durations["audio"] == pytest.approx(3.0, abs=0.1)


def test_merge_of_same_frame_rate_keeps_the_stream_copy_fast_path(tmp_path: Path, monkeypatch):
    candidates = _mixed_rate_candidates(tmp_path, True)[:2]
    commands = []
    real_run = export.run_encoded_ffmpeg

    def spy(builder, output_path, codecs, **kwargs):
        codec = real_run(builder, output_path, codecs, **kwargs)
        commands.append(builder(codec))
        return codec

    monkeypatch.setattr(export, "run_encoded_ffmpeg", spy)
    export.export_goal_clips(candidates, tmp_path / "out", "merge", output_path=tmp_path / "out" / "final.mp4")
    assert len(commands) == 2  # 只有逐段编码，没有合并时的重编码
    assert all("-r" not in command for command in commands)


def test_frame_rate_is_unified_only_when_clips_differ():
    clip = {"fps": 59.94006}
    assert export._merge_frame_rate([{"fps": 60.0}, clip], {"fps": 60.0}) is None
    assert export._merge_frame_rate([{"fps": 60.0}, clip], clip) == "60/1"
    assert export._merge_frame_rate([clip, {"fps": 60.0}], {"fps": 60.0}) == "60000/1001"
    assert export._merge_frame_rate([{"fps": 60.0}], {}) is None
    command = build_clip_command(Path("s.mp4"), 0, 1000, Path("o.mp4"), "libx264", frame_rate="60/1")
    assert command[-3:] == ["-r", "60/1", "o.mp4"]
    assert "-r" not in build_clip_command(Path("s.mp4"), 0, 1000, Path("o.mp4"), "libx264")
