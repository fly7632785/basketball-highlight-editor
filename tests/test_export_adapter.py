from pathlib import Path

import pytest

from engine.python.basketball_engine.adapters.analysis import PipelineCancelled
from engine.python.basketball_engine.adapters.export import build_clip_command, run_atomic_ffmpeg


def test_libx264_clip_command_contains_one_video_codec():
    command = build_clip_command(Path("source.mp4"), 0, 1000, Path("out.mp4"), "libx264")
    assert command.count("-c:v") == 1
    assert command[command.index("-c:v") + 1] == "libx264"


def test_clip_command_rejects_invalid_range():
    with pytest.raises(ValueError, match="INVALID_CLIP_RANGE"):
        build_clip_command(Path("source.mp4"), 1000, 1000, Path("out.mp4"))


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
