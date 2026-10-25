import json
from pathlib import Path

import pytest

from engine.python.basketball_engine.protocol import ProtocolError
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore


def _project_with_videos(tmp_path: Path, count: int = 2):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "周六比赛", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    videos = []
    for index in range(count):
        source = tmp_path / f"part{index + 1}.mp4"
        source.write_bytes(b"video")
        videos.append(store.link_video({
            "source_path": str(source),
            "source_size_bytes": 5,
            "source_mtime_ns": 1,
            "duration_ms": 60_000,
            "width": 1920,
            "height": 1440,
            "fps": 30.0,
            "video_codec": "hevc",
            "audio_codec": "aac",
            "recorded_at": f"2026-10-17T10:0{index}:00.000000Z",
        }))
    return service, store, project_root, videos


def _candidate(video_id: str, event_ms: int) -> dict:
    return {
        "id": f"{video_id}-{event_ms}",
        "video_id": video_id,
        "event_time_ms": event_ms,
        "default_start_ms": event_ms - 3000,
        "default_end_ms": event_ms + 1000,
        "review_start_ms": event_ms - 3000,
        "review_end_ms": event_ms + 1000,
        "detector_version": "test",
        "score": 0.8,
        "confidence": "review",
        "evidence_json": "{}",
    }


def test_linked_videos_keep_their_order_and_recording_time(tmp_path: Path):
    service, store, project_root, videos = _project_with_videos(tmp_path, 3)
    assert [video["sort_index"] for video in videos] == [0, 1, 2]
    assert videos[1]["recorded_at"] == "2026-10-17T10:01:00.000000Z"

    reordered = service.handle("reorder_videos", {
        "project_root": str(project_root),
        "video_ids": [videos[2]["id"], videos[0]["id"], videos[1]["id"]],
    })["videos"]
    assert [video["id"] for video in reordered] == [videos[2]["id"], videos[0]["id"], videos[1]["id"]]

    context = service.handle("open_project", {"project_root": str(project_root)})
    assert context["video"]["id"] == videos[2]["id"]
    assert [video["id"] for video in context["videos"]] == [video["id"] for video in reordered]

    with pytest.raises(ProtocolError):
        service.handle("reorder_videos", {
            "project_root": str(project_root),
            "video_ids": [videos[0]["id"]],
        })


def test_project_context_summarises_each_video(tmp_path: Path):
    service, store, project_root, videos = _project_with_videos(tmp_path)
    store.save_roi(videos[1]["id"], {"x1": 1, "y1": 2, "x2": 300, "y2": 400, "calibration": {"source": "manual"}})
    store.replace_candidates(videos[1]["id"], [_candidate(videos[1]["id"], 5000)])
    project = store.project()
    job = store.create_job(project["id"], videos[1]["id"], "analysis", {})
    store.update_job(job["id"], state="completed", stage="persist_candidates", progress=1.0)

    first, second = service.handle("open_project", {"project_root": str(project_root)})["videos"]
    assert first["roi"] is None
    assert first["analysis_job"] is None
    assert first["candidate_count"] == 0
    assert first["source_exists"] is True
    assert second["roi"]["x2"] == 300
    assert second["analysis_job"]["state"] == "completed"
    assert second["candidate_count"] == 1


def test_analysis_queue_is_persisted_and_validated(tmp_path: Path):
    service, store, project_root, videos = _project_with_videos(tmp_path)
    ids = [video["id"] for video in videos]
    queue = {"video_ids": ids, "before_seconds": 5.0, "after_seconds": 2.0}
    assert service.handle("set_analysis_queue", {
        "project_root": str(project_root),
        "video_ids": ids,
        "before_seconds": 5,
        "after_seconds": 2,
    }) == {"analysis_queue": queue}
    assert service.handle("open_project", {"project_root": str(project_root)})["analysis_queue"] == queue
    for invalid in ([ids[0], ids[0]], ["video_missing"]):
        with pytest.raises(ProtocolError):
            service.handle("set_analysis_queue", {"project_root": str(project_root), "video_ids": invalid})


def test_candidates_list_across_videos_in_segment_order(tmp_path: Path):
    service, store, project_root, videos = _project_with_videos(tmp_path)
    store.replace_candidates(videos[0]["id"], [_candidate(videos[0]["id"], 40_000)])
    store.replace_candidates(videos[1]["id"], [_candidate(videos[1]["id"], 5_000)])
    candidates = service.handle("list_candidates", {"project_root": str(project_root)})["candidates"]
    assert [(item["video_id"], item["segment"], item["event_time_ms"]) for item in candidates] == [
        (videos[0]["id"], 1, 40_000),
        (videos[1]["id"], 2, 5_000),
    ]
    only_second = service.handle("list_candidates", {
        "project_root": str(project_root),
        "video_id": videos[1]["id"],
    })["candidates"]
    assert [item["video_id"] for item in only_second] == [videos[1]["id"]]


def test_project_wide_export_snapshot_carries_each_segment(tmp_path: Path, monkeypatch):
    service, store, project_root, videos = _project_with_videos(tmp_path)
    store.replace_candidates(videos[0]["id"], [_candidate(videos[0]["id"], 40_000)])
    store.replace_candidates(videos[1]["id"], [_candidate(videos[1]["id"], 5_000)])
    monkeypatch.setattr(service, "_validated_source", lambda video: Path(video["source_path"]))
    monkeypatch.setattr(service, "_ensure_disk_space", lambda *_: None)
    captured = {}
    monkeypatch.setattr(service, "_run_export", lambda payload, job_id: captured.update(payload))

    result = service.handle("start_export", {"project_root": str(project_root), "mode": "merge"})
    snapshot = json.loads(store.get_job(result["job"]["id"])["checkpoint_json"])["candidate_snapshot"]
    assert [(item["video_id"], item["segment"]) for item in snapshot] == [
        (videos[0]["id"], 1),
        (videos[1]["id"], 2),
    ]
    assert store.get_job(result["job"]["id"])["video_id"] is None
    assert captured["candidate_snapshot"] == snapshot


def test_project_wide_export_cuts_each_clip_from_its_own_source(tmp_path: Path, monkeypatch):
    service, store, project_root, videos = _project_with_videos(tmp_path)
    store.replace_candidates(videos[0]["id"], [_candidate(videos[0]["id"], 40_000)])
    store.replace_candidates(videos[1]["id"], [_candidate(videos[1]["id"], 5_000)])
    monkeypatch.setattr(service, "_validated_source", lambda video: Path(video["source_path"]))
    monkeypatch.setattr(service, "_ensure_disk_space", lambda *_: None)
    _, _, snapshot = service._export_candidate_snapshot(store, None, {})
    exported = []

    def fake_export(candidates, output_dir, mode, output_path=None, **_):
        exported.extend(candidates)
        output_dir.mkdir(parents=True, exist_ok=True)
        clip = output_dir / "clip.mp4"
        clip.write_bytes(b"clip")
        return {"files": [str(clip)], "clip_files": [str(clip)], "duration_ms": 8000, "processing_ms": 1}

    monkeypatch.setattr("engine.python.basketball_engine.service.export_goal_clips", fake_export)
    monkeypatch.setattr(service, "inspect_video", lambda payload: {})
    result = service._execute_export({
        "project_root": str(project_root),
        "mode": "separate",
        "candidate_snapshot": snapshot,
        "output_dir": str(tmp_path / "out"),
    })
    assert [Path(item["source_path"]).name for item in exported] == ["part1.mp4", "part2.mp4"]
    assert result["export"]["video_id"] is None
