import json
import subprocess
from pathlib import Path

import pytest

from engine.python.basketball_engine.media_tools import resolve_media_tool
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore


def _ffmpeg_or_skip() -> str:
    ffmpeg = resolve_media_tool("ffmpeg")
    if not resolve_media_tool("ffprobe"):
        pytest.skip("需要 ffmpeg/ffprobe")
    return ffmpeg


def _portrait_coded_clip(tmp_path: Path, ffmpeg: str, displayed_landscape: bool) -> Path:
    """编码是 1080x1920；displayed_landscape 时带 -90° 显示矩阵，播放器会转成横屏。"""
    coded = tmp_path / "coded.mp4"
    subprocess.run(
        [
            ffmpeg, "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=1080x1920:rate=30",
            "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(coded),
        ],
        check=True,
    )
    if not displayed_landscape:
        return coded
    rotated = tmp_path / "displayed_landscape.mp4"
    subprocess.run(
        [ffmpeg, "-v", "error", "-y", "-display_rotation:v:0", "-90", "-i", str(coded), "-c", "copy", str(rotated)],
        check=True,
    )
    return rotated


def test_inspect_reports_the_displayed_size_of_a_rotated_video(tmp_path: Path):
    ffmpeg = _ffmpeg_or_skip()
    rotated = _portrait_coded_clip(tmp_path, ffmpeg, displayed_landscape=True)
    plain = _portrait_coded_clip(tmp_path, ffmpeg, displayed_landscape=False)

    service = EngineService()
    landscape = service.handle("inspect_video", {"video_path": str(rotated)})
    portrait = service.handle("inspect_video", {"video_path": str(plain)})

    assert (landscape["width"], landscape["height"]) == (1920, 1080)
    assert (portrait["width"], portrait["height"]) == (1080, 1920)


def test_open_project_corrects_a_stored_portrait_size_and_drops_drawn_work(tmp_path: Path):
    ffmpeg = _ffmpeg_or_skip()
    source = _portrait_coded_clip(tmp_path, ffmpeg, displayed_landscape=True)
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "横竖测试", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(source),
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "duration_ms": 2000,
        "width": 1080,
        "height": 1920,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": None,
    })
    store.save_roi(video["id"], {"x1": 100, "y1": 200, "x2": 400, "y2": 500})
    store.replace_candidates(video["id"], [{
        "id": "candidate-1",
        "video_id": video["id"],
        "event_time_ms": 1000,
        "default_start_ms": 0,
        "default_end_ms": 1500,
        "review_start_ms": 0,
        "review_end_ms": 1500,
        "detector_version": "test",
        "score": 0.8,
        "confidence": "review",
        "evidence_json": "{}",
    }])

    context = service.handle("open_project", {"project_root": str(project_root)})

    assert context["orientation_corrected"] == [video["id"]]
    corrected = context["videos"][0]
    assert (corrected["width"], corrected["height"]) == (1920, 1080)
    assert corrected["roi"] is None
    assert corrected["candidate_count"] == 0

    again = service.handle("open_project", {"project_root": str(project_root)})
    assert "orientation_corrected" not in again


def _probe_with(monkeypatch, streams: list[dict]) -> None:
    payload = json.dumps({"format": {"duration": "10.0"}, "streams": streams})
    monkeypatch.setattr(
        "engine.python.basketball_engine.service.subprocess.run",
        lambda *args, **kwargs: type("Completed", (), {"stdout": payload})(),
    )


def _inspect_fake(tmp_path: Path, monkeypatch, streams: list[dict]) -> dict:
    source = tmp_path / "fixture.mp4"
    source.write_bytes(b"video")
    _probe_with(monkeypatch, streams)
    return EngineService().handle("inspect_video", {"video_path": str(source)})


def test_half_turn_rotation_keeps_the_stored_size(tmp_path: Path, monkeypatch):
    info = _inspect_fake(tmp_path, monkeypatch, [{
        "codec_type": "video",
        "width": 1080,
        "height": 1920,
        "r_frame_rate": "30/1",
        "side_data_list": [{"rotation": 180}],
    }])

    assert (info["width"], info["height"]) == (1080, 1920)


def test_old_rotate_tag_is_honoured_when_there_is_no_display_matrix(tmp_path: Path, monkeypatch):
    info = _inspect_fake(tmp_path, monkeypatch, [{
        "codec_type": "video",
        "width": 1080,
        "height": 1920,
        "r_frame_rate": "30/1",
        "tags": {"rotate": "-90"},
    }])

    assert (info["width"], info["height"]) == (1920, 1080)


def test_cover_art_is_not_used_for_the_footage_size(tmp_path: Path, monkeypatch):
    info = _inspect_fake(tmp_path, monkeypatch, [
        {
            "codec_type": "video",
            "width": 720,
            "height": 1280,
            "r_frame_rate": "90000/1",
            "disposition": {"attached_pic": 1},
        },
        {
            "codec_type": "video",
            "width": 1920,
            "height": 1080,
            "r_frame_rate": "30/1",
            "disposition": {"attached_pic": 0},
        },
    ])

    assert (info["width"], info["height"]) == (1920, 1080)
    assert info["fps"] == pytest.approx(30.0)


def test_open_project_leaves_videos_alone_when_the_stored_size_is_not_a_swap(tmp_path: Path):
    ffmpeg = _ffmpeg_or_skip()
    source = _portrait_coded_clip(tmp_path, ffmpeg, displayed_landscape=True)
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "非互换测试", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(source),
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "duration_ms": 2000,
        "width": 1280,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": None,
    })
    store.save_roi(video["id"], {"x1": 100, "y1": 200, "x2": 400, "y2": 500})

    context = service.handle("open_project", {"project_root": str(project_root)})

    assert "orientation_corrected" not in context
    assert context["videos"][0]["roi"] is not None
    assert (context["videos"][0]["width"], context["videos"][0]["height"]) == (1280, 720)


def test_a_file_whose_only_video_stream_is_cover_art_still_reports_its_size(tmp_path: Path, monkeypatch):
    info = _inspect_fake(tmp_path, monkeypatch, [{
        "codec_type": "video",
        "width": 1920,
        "height": 1080,
        "r_frame_rate": "30/1",
        "disposition": {"attached_pic": 1},
    }])

    assert (info["width"], info["height"]) == (1920, 1080)
