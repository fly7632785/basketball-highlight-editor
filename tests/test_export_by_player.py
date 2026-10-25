import json
import shutil
import subprocess
from pathlib import Path

import pytest

from engine.python.basketball_engine.media_tools import resolve_media_tool
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore


def _tools_or_skip() -> tuple[str, str]:
    ffmpeg, ffprobe = resolve_media_tool("ffmpeg"), resolve_media_tool("ffprobe")
    if not shutil.which(ffmpeg) or not shutil.which(ffprobe):
        pytest.skip("需要 ffmpeg/ffprobe")
    return ffmpeg, ffprobe


def _duration(ffprobe: str, path: Path) -> float:
    out = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    return float(json.loads(out)["format"]["duration"])


def _candidate(video_id: str, event_ms: int) -> dict:
    return {
        "id": f"c{event_ms}",
        "video_id": video_id,
        "event_time_ms": event_ms,
        "default_start_ms": event_ms - 500,
        "default_end_ms": event_ms + 500,
        "review_start_ms": event_ms - 500,
        "review_end_ms": event_ms + 500,
        "detector_version": "test",
        "score": 0.8,
        "confidence": "review",
        "evidence_json": "{}",
    }


@pytest.fixture()
def tagged_project(tmp_path: Path, monkeypatch):
    ffmpeg, ffprobe = _tools_or_skip()
    source = tmp_path / "game.mp4"
    subprocess.run(
        [
            ffmpeg, "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440",
            "-t", "8", "-c:v", "mpeg4", "-c:a", "aac", str(source),
        ],
        check=True,
    )
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "按标签", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(source),
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "duration_ms": 8000,
        "width": 320,
        "height": 240,
        "fps": 30.0,
        "video_codec": "mpeg4",
        "audio_codec": "aac",
    })
    store.replace_candidates(video["id"], [_candidate(video["id"], ms) for ms in (1000, 3000, 5000, 7000)])
    zhang = service.handle("create_player", {"project_root": str(project_root), "name": "张三"})["player"]["id"]
    li = service.handle("create_player", {"project_root": str(project_root), "name": "李四/队长"})["player"]["id"]
    store.set_candidate_player("c1000", zhang)
    store.set_candidate_player("c5000", zhang)
    store.set_candidate_player("c3000", li)
    monkeypatch.setattr(service, "_validated_source", lambda video: Path(video["source_path"]))
    monkeypatch.setattr(service, "_ensure_disk_space", lambda *_: None)
    return service, store, project_root, ffprobe, (zhang, li)


def test_each_selected_tag_becomes_its_own_merged_video(tmp_path: Path, tagged_project):
    service, store, project_root, ffprobe, (zhang, li) = tagged_project
    _, _, snapshot = service._export_candidate_snapshot(
        store, None, {"player_ids": [zhang, li], "include_unassigned": False},
    )
    out = tmp_path / "out"

    result = service._execute_export({
        "project_root": str(project_root),
        "mode": "merge_by_player",
        "candidate_snapshot": snapshot,
        "output_dir": str(out),
    })

    assert sorted(path.name for path in out.iterdir()) == ["张三.mp4", "李四_队长.mp4"]
    assert _duration(ffprobe, out / "张三.mp4") == pytest.approx(2.0, abs=0.3)
    assert _duration(ffprobe, out / "李四_队长.mp4") == pytest.approx(1.0, abs=0.3)
    assert result["export"]["mode"] == "merge_by_player"
    assert result["export"]["candidate_count"] == 3


def test_untagged_clips_get_their_own_video_only_when_included(tmp_path: Path, tagged_project):
    service, store, project_root, _, (zhang, _) = tagged_project
    _, _, snapshot = service._export_candidate_snapshot(
        store, None, {"player_ids": [zhang], "include_unassigned": True},
    )
    out = tmp_path / "out"

    service._execute_export({
        "project_root": str(project_root),
        "mode": "merge_by_player",
        "candidate_snapshot": snapshot,
        "output_dir": str(out),
    })

    assert sorted(path.name for path in out.iterdir()) == ["张三.mp4", "未标记.mp4"]
