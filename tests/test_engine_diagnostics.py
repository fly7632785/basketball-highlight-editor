from pathlib import Path
import shutil
import subprocess
import time

import pytest

from engine.python.basketball_engine.adapters import export
from engine.python.basketball_engine.diagnostics import environment_summary
from engine.python.basketball_engine.media_tools import resolve_media_tool
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore


def _linked_video(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "测试项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    source = tmp_path / "source.mp4"
    source.write_bytes(b"fixture")
    video = store.link_video({
        "source_path": str(source),
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "duration_ms": 7_200_000,
        "width": 3840,
        "height": 2160,
        "fps": 29.97,
        "video_codec": "hevc",
        "audio_codec": "aac",
    })
    store.save_roi(video["id"], {"x1": 1500, "y1": 400, "x2": 2000, "y2": 900})
    model = tmp_path / "model.pt"
    model.write_bytes(b"test")
    return service, project_root, video, model


def test_failed_analysis_logs_the_video_and_the_stage_it_failed_in(tmp_path: Path, monkeypatch, capsys):
    service, project_root, video, model = _linked_video(tmp_path)

    def fail_in_proxy(commands, output, on_stage, **kwargs):
        on_stage("prepare_proxy", 0.02)
        kwargs["output_callback"]("scan_coarse", "device=cuda")
        raise RuntimeError("create_proxy.py 执行失败: Unknown decoder 'hevc_cuvid'")

    monkeypatch.setattr("engine.python.basketball_engine.service.run_pipeline", fail_in_proxy)
    job = service.handle("start_analysis", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "model_path": str(model),
    })["job"]
    for _ in range(100):
        current = service.handle("get_job", {"project_root": str(project_root), "job_id": job["id"]})["job"]
        if current["state"] == "failed":
            break
        time.sleep(0.02)
    assert current["state"] == "failed"

    log = capsys.readouterr().err
    label = f"[bhe] analysis job={job['id']}"
    assert f"{label} start mode=standard" in log
    assert "3840x2160 29.97fps video=hevc audio=aac duration=7200.0s" in log
    assert f"{label} stage=prepare_proxy progress=0.02" in log
    assert f"{label} scan_coarse device=cuda" in log
    assert f"{label} failed stage=prepare_proxy" in log
    assert "code=ANALYSIS_FAILED: create_proxy.py 执行失败: Unknown decoder 'hevc_cuvid'" in log
    assert "Traceback" in log


def test_inspect_logs_the_video_specs(tmp_path: Path, capsys):
    ffmpeg = resolve_media_tool("ffmpeg")
    if not shutil.which(ffmpeg) or not shutil.which(resolve_media_tool("ffprobe")):
        pytest.skip("需要 ffmpeg/ffprobe")
    source = tmp_path / "game.mp4"
    subprocess.run(
        [
            ffmpeg, "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30",
            "-t", "1", "-c:v", "mpeg4", str(source),
        ],
        check=True,
    )
    EngineService().handle("inspect_video", {"video_path": str(source)})
    log = capsys.readouterr().err
    assert "[bhe] inspect game.mp4 320x240 30.00fps video=mpeg4 audio=None duration=1.0s" in log
    assert "free_disk=" in log


def test_export_logs_each_encoder_that_failed(tmp_path: Path, monkeypatch, capsys):
    def fake_ffmpeg(command, output_path, **_kwargs):
        if "h264_nvenc" in command:
            raise subprocess.CalledProcessError(1, command, stderr="No NVENC capable devices found")
        output_path.write_bytes(b"clip")

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fake_ffmpeg)
    codec = export.run_encoded_ffmpeg(
        lambda codec: ["ffmpeg", "-c:v", codec],
        tmp_path / "clip.mp4",
        ["h264_nvenc", "libx264"],
    )
    assert codec == "libx264"
    assert "[bhe] encoder h264_nvenc failed, trying libx264" in capsys.readouterr().err


def test_environment_summary_names_the_machine_and_ffmpeg():
    summary = environment_summary()
    assert summary.startswith("environment engine=")
    for key in ("python=", "os=", "cpu=", "memory=", "ffmpeg="):
        assert key in summary
    assert "memory=unknown" not in summary
