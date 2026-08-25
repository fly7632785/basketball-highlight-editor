import json
import subprocess
import sys
import time
import threading
from pathlib import Path

import pytest
import refine_dynamic_candidates

from engine.python.basketball_engine.service import (
    ANALYSIS_ALGORITHM_VERSION,
    EngineService,
)
from engine.python.basketball_engine.storage import ProjectStore
from engine.python.basketball_engine.protocol import ProtocolError, parse_request


def test_inspect_video_rejects_non_object_ffprobe_output(tmp_path: Path, monkeypatch):
    source = tmp_path / "invalid-metadata.mp4"
    source.write_bytes(b"video")
    monkeypatch.setattr(
        "engine.python.basketball_engine.service.subprocess.run",
        lambda *args, **kwargs: type("Completed", (), {"stdout": "[]"})(),
    )

    with pytest.raises(ProtocolError) as error:
        EngineService().inspect_video({"video_path": str(source)})

    assert error.value.code == "VIDEO_OPEN_FAILED"


def test_inspect_video_rejects_invalid_ffprobe_duration(tmp_path: Path, monkeypatch):
    source = tmp_path / "invalid-duration.mp4"
    source.write_bytes(b"video")
    monkeypatch.setattr(
        "engine.python.basketball_engine.service.subprocess.run",
        lambda *args, **kwargs: type(
            "Completed", (), {
                "stdout": json.dumps({
                    "format": {"duration": "not-a-number"},
                    "streams": [{"codec_type": "video", "width": 960, "height": 720}],
                }),
            },
        )(),
    )

    with pytest.raises(ProtocolError) as error:
        EngineService().inspect_video({"video_path": str(source)})

    assert error.value.code == "VIDEO_OPEN_FAILED"


def test_inspect_video_uses_runtime_ffprobe_and_surfaces_stderr(tmp_path: Path, monkeypatch):
    source = tmp_path / "broken.mp4"
    source.write_bytes(b"video")
    ffprobe = tmp_path / "runtime" / "bin" / "ffprobe"
    ffprobe.parent.mkdir(parents=True)
    ffprobe.write_bytes(b"binary")
    ffprobe.chmod(0o755)
    calls = []

    def fake_run(command, **_kwargs):
        calls.append(command)
        raise subprocess.CalledProcessError(
            8,
            command,
            stderr="Unrecognized option 'show_entries'.",
        )

    monkeypatch.setattr(
        "engine.python.basketball_engine.service.resolve_media_tool",
        lambda name: str(ffprobe) if name == "ffprobe" else name,
    )
    monkeypatch.setattr(
        "engine.python.basketball_engine.service.subprocess.run",
        fake_run,
    )

    with pytest.raises(ProtocolError) as error:
        EngineService().inspect_video({"video_path": str(source)})

    assert calls[0][0] == str(ffprobe)
    assert "exit=8" in error.value.message
    assert "Unrecognized option" in error.value.message


def test_create_project_and_statistics(tmp_path: Path):
    service = EngineService()
    result = service.handle("create_project", {"name": "测试项目", "root_path": str(tmp_path / "project")})
    assert result["project"]["name"] == "测试项目"

    stats = service.handle("get_statistics", {"project_root": str(tmp_path / "project")})
    assert stats["statistics"]["candidate_count"] == 0
    assert stats["statistics"]["goal_count"] == 0


def test_analysis_range_is_persisted_and_invalidates_candidates(tmp_path: Path):
    store = ProjectStore(tmp_path / "project")
    store.initialize()
    store.create_project("project-1", "范围测试")
    video = store.link_video({
        "id": "video-1",
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 60_000,
        "width": 1280,
        "height": 720,
    })
    store.replace_candidates(video["id"], [{
        "id": "candidate-1", "video_id": video["id"], "event_time_ms": 10_000,
        "default_start_ms": 4_000, "default_end_ms": 13_000,
        "review_start_ms": 4_000, "review_end_ms": 13_000,
        "detector_version": "test", "evidence_json": "{}",
    }])
    updated = store.set_analysis_range(video["id"], 5_000, 50_000)
    assert updated["analysis_start_ms"] == 5_000
    assert updated["analysis_end_ms"] == 50_000
    assert len(store.list_candidates(video["id"])) == 1


def test_delete_project_removes_project_files_but_not_source_video(tmp_path: Path):
    project_root = tmp_path / "project"
    source = tmp_path / "source.mp4"
    source.write_bytes(b"source")
    service = EngineService()
    created = service.handle(
        "create_project",
        {"name": "待删除项目", "root_path": str(project_root)},
    )

    deleted = service.handle("delete_project", {"project_root": str(project_root)})

    assert deleted == {
        "deleted": True,
        "project_root": str(project_root.resolve()),
        "project_id": created["project"]["id"],
    }
    assert not project_root.exists()
    assert source.read_bytes() == b"source"


def test_stale_read_does_not_recreate_deleted_project(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle(
        "create_project",
        {"name": "待删除项目", "root_path": str(project_root)},
    )
    service.handle("delete_project", {"project_root": str(project_root)})

    with pytest.raises(ProtocolError) as error:
        service.handle("get_statistics", {"project_root": str(project_root)})

    assert error.value.code == "PROJECT_NOT_FOUND"
    assert not project_root.exists()


def test_delete_project_rejects_source_video_inside_project(tmp_path: Path):
    project_root = tmp_path / "project"
    source = project_root / "source.mp4"
    service = EngineService()
    service.handle(
        "create_project",
        {"name": "保护原视频", "root_path": str(project_root)},
    )
    source.write_bytes(b"source")
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    store.link_video(
        {
            "source_path": str(source),
            "source_size_bytes": source.stat().st_size,
            "source_mtime_ns": source.stat().st_mtime_ns,
            "duration_ms": 1_000,
            "width": 960,
            "height": 720,
            "fps": 30.0,
            "video_codec": "h264",
            "audio_codec": "aac",
        }
    )

    with pytest.raises(ProtocolError) as error:
        service.handle("delete_project", {"project_root": str(project_root)})

    assert error.value.code == "PROJECT_SOURCE_INSIDE_PROJECT"
    assert project_root.is_dir()
    assert source.read_bytes() == b"source"


def test_delete_project_resolves_relative_source_against_project_root(tmp_path: Path):
    project_root = tmp_path / "project"
    source = project_root / "source.mp4"
    service = EngineService()
    service.handle(
        "create_project",
        {"name": "相对路径保护", "root_path": str(project_root)},
    )
    source.write_bytes(b"source")
    store = ProjectStore(project_root)
    store.link_video({
        "source_path": "source.mp4",
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "duration_ms": 1_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })

    with pytest.raises(ProtocolError) as error:
        service.handle("delete_project", {"project_root": str(project_root)})

    assert error.value.code == "PROJECT_SOURCE_INSIDE_PROJECT"
    assert source.exists()


def test_delete_project_rejects_database_active_job_without_live_thread(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "陈旧任务保护", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    job = store.create_job(project["id"], None, "analysis")
    store.update_job(job["id"], state="running", stage="refine")

    with pytest.raises(ProtocolError) as error:
        service.handle("delete_project", {"project_root": str(project_root)})

    assert error.value.code == "PROJECT_BUSY"
    assert project_root.exists()


def test_delete_project_rejects_live_job(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "运行中项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    job = store.create_job(project["id"], None, "analysis")
    release = threading.Event()
    worker = threading.Thread(target=release.wait, args=(2,), daemon=True)
    worker.start()
    service._job_threads[job["id"]] = worker

    with pytest.raises(ProtocolError) as error:
        service.handle("delete_project", {"project_root": str(project_root)})

    assert error.value.code == "PROJECT_BUSY"
    assert project_root.exists()
    release.set()
    worker.join(timeout=1)


def test_cleanup_artifacts_rejects_live_job_and_preserves_files(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "清理保护", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    artifact = project_root / "artifacts" / "review_clips" / "candidate.mp4"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_bytes(b"clip")
    job = store.create_job(project["id"], None, "analysis")
    store.update_job(job["id"], state="running", stage="refine")
    release = threading.Event()
    worker = threading.Thread(target=release.wait, args=(2,), daemon=True)
    worker.start()
    service._job_threads[job["id"]] = worker

    with pytest.raises(ProtocolError) as error:
        service.handle("cleanup_artifacts", {"project_root": str(project_root)})

    assert error.value.code == "PROJECT_BUSY"
    assert artifact.read_bytes() == b"clip"
    release.set()
    worker.join(timeout=1)


def test_cleanup_artifacts_removes_requested_artifacts_when_idle(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "清理空闲", "root_path": str(project_root)})
    review_clip = project_root / "artifacts" / "review_clips" / "candidate.mp4"
    export = project_root / "artifacts" / "exports" / "highlights.mp4"
    review_clip.parent.mkdir(parents=True, exist_ok=True)
    export.parent.mkdir(parents=True, exist_ok=True)
    review_clip.write_bytes(b"clip")
    export.write_bytes(b"export")

    result = service.handle(
        "cleanup_artifacts",
        {"project_root": str(project_root), "include_exports": True},
    )

    assert result["removed"]
    assert not review_clip.exists()
    assert not export.exists()


def test_list_exports_returns_recent_export_metrics(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "导出记录", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    export = store.create_export({
        "project_id": project["id"],
        "output_path": str(tmp_path / "highlights.mp4"),
        "mode": "merge",
        "candidate_count": 3,
        "duration_ms": 27_000,
        "processing_ms": 1_200,
        "metadata": {"files": ["highlights.mp4"]},
    })

    result = service.handle("list_exports", {
        "project_root": str(project_root),
        "limit": 5,
    })

    assert result["exports"][0]["id"] == export["id"]
    assert result["exports"][0]["candidate_count"] == 3
    assert result["exports"][0]["metadata"] == {"files": ["highlights.mp4"]}


def test_export_rejects_overwriting_source_video(tmp_path: Path):
    project_root = tmp_path / "project"
    source = tmp_path / "source.mp4"
    source.write_bytes(b"source")
    service = EngineService()
    service.handle("create_project", {"name": "禁止覆盖", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(source),
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "duration_ms": 1_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.replace_candidates(video["id"], [{
        "id": "candidate-1", "video_id": video["id"], "event_time_ms": 500,
        "default_start_ms": 0, "default_end_ms": 900,
        "review_start_ms": 0, "review_end_ms": 900,
        "detector_version": "test", "score": 0.9, "confidence": "high",
        "evidence_json": "{}",
    }])

    started = service.handle(
        "start_export",
        {
            "project_root": str(project_root),
            "video_id": video["id"],
            "mode": "merge",
            "output_path": str(source),
        },
    )
    service._job_threads[started["job"]["id"]].join(timeout=2)
    job = store.get_job(started["job"]["id"])

    assert job is not None
    assert job["state"] == "failed"
    assert job["error_code"] == "EXPORT_SOURCE_CONFLICT"
    assert source.read_bytes() == b"source"


def test_start_analysis_rejects_existing_stale_job(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "避免重复", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    job = service._create_analysis_job({
        "project_root": str(project_root),
        "video_id": video["id"],
    })["job"]
    store.update_job(job["id"], state="running", stage="coarse_scan")

    with pytest.raises(ProtocolError) as error:
        service.handle("start_analysis", {
            "project_root": str(project_root),
            "video_id": video["id"],
        })

    assert error.value.code == "JOB_RECOVERY_REQUIRED"


def test_start_export_rejects_existing_stale_export_job(tmp_path: Path):
    project_root = tmp_path / "project"
    source = tmp_path / "source.mp4"
    source.write_bytes(b"source")
    service = EngineService()
    service.handle("create_project", {"name": "避免重复导出", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    video = store.link_video({
        "source_path": str(source),
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    job = store.create_job(project["id"], video["id"], "export")
    store.update_job(job["id"], state="running", stage="encode")

    with pytest.raises(ProtocolError) as error:
        service.handle(
            "start_export",
            {"project_root": str(project_root), "video_id": video["id"]},
        )

    assert error.value.code == "JOB_RECOVERY_REQUIRED"


def test_retry_analysis_rejects_export_job(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "任务类型", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    job = store.create_job(project["id"], None, "export")
    store.update_job(job["id"], state="failed", stage="export")

    with pytest.raises(ProtocolError) as error:
        service.handle(
            "retry_analysis",
            {"project_root": str(project_root), "job_id": job["id"]},
        )

    assert error.value.code == "JOB_NOT_FOUND"


def test_retry_analysis_accepts_failed_job(tmp_path: Path, monkeypatch):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "失败后重试", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    job = service._create_analysis_job({
        "project_root": str(project_root),
        "video_id": video["id"],
        "sample_fps": 10,
    })["job"]
    store.update_job(
        job["id"],
        state="failed",
        stage="coarse_scan",
        error_code="ANALYSIS_FAILED",
        error_message="模拟失败",
    )
    started_payload = {}

    def fake_start_analysis(payload):
        started_payload.update(payload)
        return {"job": {"id": "retry-job", "state": "queued"}}

    monkeypatch.setattr(service, "start_analysis", fake_start_analysis)

    result = service.handle("retry_analysis", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "job_id": job["id"],
    })

    assert result["job"]["id"] == "retry-job"
    assert started_payload["sample_fps"] == 10
    replaced = store.get_job(job["id"])
    assert replaced["state"] == "cancelled"
    assert replaced["error_code"] == "JOB_RETRIED"


def test_jsonl_hello(tmp_path: Path):
    root = Path(__file__).resolve().parents[1]
    command = [sys.executable, "-m", "basketball_engine"]
    environment = {"PYTHONPATH": str(root / "engine/python")}
    process = subprocess.run(
        command,
        input=json.dumps(
            {
                "protocol_version": "1.0",
                "type": "request",
                "request_id": "hello-1",
                "command": "hello",
                "payload": {},
            }
        )
        + "\n",
        text=True,
        capture_output=True,
        env={**environment},
        check=True,
    )
    output = json.loads(process.stdout)
    assert output["ok"] is True
    assert output["request_id"] == "hello-1"
    assert "create_project" in output["payload"]["capabilities"]
    assert "open_project" in output["payload"]["capabilities"]
    assert "list_recent_projects" in output["payload"]["capabilities"]
    assert "get_active_jobs" in output["payload"]["capabilities"]


def test_hello_capabilities_match_registered_handlers():
    service = EngineService()
    capabilities = set(service.hello({})["capabilities"])
    assert capabilities == set(service._handlers())


def test_get_active_jobs_exposes_checkpoint_and_stale_recovery_state(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "可恢复项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    job = service._create_analysis_job({
        "project_root": str(project_root),
        "video_id": video["id"],
        "sample_fps": 8,
    })["job"]
    store.update_job(
        job["id"],
        state="running",
        stage="coarse_scan",
        progress=0.42,
        checkpoint={"proxy_video": "artifacts/proxies/proxy.mp4", "frame": 123},
    )

    recovered = EngineService().handle("get_active_jobs", {
        "project_root": str(project_root),
        "video_id": video["id"],
    })

    assert recovered["count"] == 1
    active = recovered["jobs"][0]
    assert active["id"] == job["id"]
    assert active["state"] == "running"
    assert active["stage"] == "coarse_scan"
    assert active["progress"] == pytest.approx(0.42)
    assert active["checkpoint"]["frame"] == 123
    assert active["runtime_state"] == "stale"
    assert active["recovery_state"] == "stale_recoverable"
    assert active["recoverable"] is True
    assert store.get_job(job["id"])["state"] == "running"


def test_get_latest_job_returns_terminal_checkpoint_for_reopened_project(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "已完成项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    job = service._create_analysis_job({
        "project_root": str(project_root),
        "video_id": video["id"],
        "mode": "fast",
    })["job"]
    store.update_job(
        job["id"],
        state="completed",
        stage="persist_candidates",
        progress=1.0,
        checkpoint={"mode": "fast", "total_elapsed_ms": 1234},
    )

    latest = EngineService().handle("get_latest_job", {
        "project_root": str(project_root),
        "video_id": video["id"],
    })

    assert latest["job"]["id"] == job["id"]
    assert latest["job"]["state"] == "completed"
    assert latest["job"]["checkpoint"]["mode"] == "fast"


def test_get_latest_job_uses_a_stable_tiebreaker_for_equal_created_at(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "排序项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    first = store.create_job(project["id"], None, "analysis", {"marker": "first"})
    second = store.create_job(project["id"], None, "analysis", {"marker": "second"})

    with store.connect() as connection:
        connection.execute(
            "UPDATE jobs SET created_at = ?, updated_at = ? WHERE id IN (?, ?)",
            ("2026-08-13T00:00:00.000+00:00", "2026-08-13T00:00:00.000+00:00", first["id"], second["id"]),
        )

    latest = service.handle("get_latest_job", {"project_root": str(project_root)})

    assert latest["job"]["id"] == max(first["id"], second["id"])


def test_candidate_previews_use_at_most_two_ffmpeg_processes(
    tmp_path: Path,
    monkeypatch,
):
    service, store, video, _ = _analysis_fixture(tmp_path)
    project = store.project()
    assert project is not None
    job = store.create_job(project["id"], video["id"], "analysis")
    rows = [
        {"event_time_ms": 1_000},
        {"event_time_ms": 2_000},
        {"event_time_ms": 3_000},
    ]
    active = 0
    maximum = 0
    lock = threading.Lock()

    class FakeProcess:
        def __init__(self, command, **_kwargs):
            nonlocal active, maximum
            self.returncode = 0
            self._released = False
            Path(command[-1]).parent.mkdir(parents=True, exist_ok=True)
            Path(command[-1]).write_bytes(b"frame")
            with lock:
                active += 1
                maximum = max(maximum, active)

        def communicate(self, timeout=None):
            nonlocal active
            if not self._released:
                time.sleep(0.03)
                self._released = True
                with lock:
                    active -= 1
            return "", ""

    monkeypatch.setattr("engine.python.basketball_engine.service.subprocess.Popen", FakeProcess)

    counts = service._prepare_candidate_previews(
        store=store,
        source=tmp_path / "source.mp4",
        video=video,
        video_id=video["id"],
        rows=rows,
        job_id=job["id"],
        cancel_event=threading.Event(),
    )

    assert counts == {"generated": 3, "reused": 0, "failed": 0}
    assert maximum == 2


def test_get_active_jobs_does_not_start_duplicate_work_and_marks_live_worker(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "运行中项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    job = service._create_analysis_job({
        "project_root": str(project_root),
        "video_id": video["id"],
    })["job"]
    release = threading.Event()
    worker = threading.Thread(target=release.wait, args=(2,), daemon=True)
    worker.start()
    service._job_threads[job["id"]] = worker

    active = service.handle("get_active_jobs", {"project_root": str(project_root)})

    assert active["count"] == 1
    assert active["jobs"][0]["runtime_state"] == "running"
    assert active["jobs"][0]["recovery_state"] == "worker_attached"
    assert active["jobs"][0]["recoverable"] is False
    assert len(service._job_threads) == 1
    release.set()
    worker.join(timeout=1)


def test_open_project_returns_persisted_context(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    created = service.handle(
        "create_project",
        {"name": "可恢复项目", "root_path": str(project_root)},
    )
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    roi = store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    store.replace_candidates(video["id"], [{
        "id": "persisted-candidate",
        "video_id": video["id"],
        "roi_id": roi["id"],
        "event_time_ms": 1000,
        "default_start_ms": 0,
        "default_end_ms": 4000,
        "review_start_ms": 0,
        "review_end_ms": 4000,
        "detector_version": "test",
        "score": 0.9,
        "confidence": "high",
        "evidence_json": "{}",
    }])
    store.review_candidate("persisted-candidate", "goal", "确认")

    reopened = EngineService().handle(
        "open_project", {"project_root": str(project_root)}
    )

    assert reopened["database_path"] == str(project_root / "project.db")
    assert reopened["project"]["id"] == created["project"]["id"]
    assert reopened["video"]["id"] == video["id"]
    assert reopened["roi"]["id"] == roi["id"]
    assert reopened["statistics"]["candidate_count"] == 1
    assert reopened["statistics"]["goal_count"] == 1


def test_open_project_marks_missing_source_without_losing_project_data(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "失效视频", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "moved.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })

    reopened = service.handle("open_project", {"project_root": str(project_root)})

    assert reopened["video"]["id"] == video["id"]
    assert reopened["video"]["source_exists"] is False
    assert reopened["video"]["source_status"] == "missing"


def test_relink_video_updates_media_reference_and_keeps_video_id(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "重新定位", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "old.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    replacement = tmp_path / "replacement.mp4"
    replacement.write_bytes(b"fixture")
    service.inspect_video = lambda payload: {
        "source_path": str(replacement.resolve()),
        "source_size_bytes": replacement.stat().st_size,
        "source_mtime_ns": replacement.stat().st_mtime_ns,
        "duration_ms": 30_000,
        "width": 1920,
        "height": 1080,
        "fps": 60.0,
        "video_codec": "hevc",
        "audio_codec": "aac",
    }

    result = service.handle("relink_video", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "video_path": str(replacement),
    })

    assert result["video"]["id"] == video["id"]
    assert result["video"]["source_path"] == str(replacement.resolve())
    assert result["video"]["duration_ms"] == 30_000
    assert result["video"]["source_exists"] is True


def test_relink_video_invalidates_analysis_when_content_changes_with_same_media_metadata(tmp_path: Path):
    project_root = tmp_path / "project"
    old_source = tmp_path / "old.mp4"
    new_source = tmp_path / "new.mp4"
    old_source.write_bytes(b"old-content")
    new_source.write_bytes(b"new-content")
    service = EngineService()
    service.handle("create_project", {"name": "同规格换内容", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(old_source),
        "source_size_bytes": old_source.stat().st_size,
        "source_mtime_ns": old_source.stat().st_mtime_ns,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    roi = store.save_roi(video["id"], {"x1": 100, "y1": 100, "x2": 300, "y2": 300})
    store.replace_candidates(video["id"], [{
        "id": "candidate-same-shape",
        "video_id": video["id"],
        "roi_id": roi["id"],
        "event_time_ms": 10_000,
        "default_start_ms": 4_000,
        "default_end_ms": 13_000,
        "review_start_ms": 4_000,
        "review_end_ms": 13_000,
        "detector_version": "test",
        "score": 0.8,
        "confidence": "review",
        "evidence_json": "{}",
    }])
    service.inspect_video = lambda payload: {
        "source_path": str(new_source.resolve()),
        "source_size_bytes": old_source.stat().st_size,
        "source_mtime_ns": new_source.stat().st_mtime_ns,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    }

    result = service.handle("relink_video", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "video_path": str(new_source),
    })

    assert result["video"]["analysis_invalidated"] is True
    assert store.list_candidates(video["id"]) == []
    assert store.active_roi(video["id"]) is None


def test_relink_video_invalidates_analysis_when_media_fingerprint_changes(tmp_path: Path):
    project_root = tmp_path / "project"
    old_source = tmp_path / "old.mp4"
    new_source = tmp_path / "new.mp4"
    old_source.write_bytes(b"old")
    new_source.write_bytes(b"new-media")
    service = EngineService()
    service.handle("create_project", {"name": "换视频清理分析", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(old_source),
        "source_size_bytes": old_source.stat().st_size,
        "source_mtime_ns": old_source.stat().st_mtime_ns,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    roi = store.save_roi(video["id"], {"x1": 100, "y1": 100, "x2": 300, "y2": 300})
    store.replace_candidates(video["id"], [{
        "id": "candidate-1",
        "video_id": video["id"],
        "roi_id": roi["id"],
        "event_time_ms": 10_000,
        "default_start_ms": 4_000,
        "default_end_ms": 13_000,
        "review_start_ms": 4_000,
        "review_end_ms": 13_000,
        "detector_version": "test",
        "score": 0.8,
        "confidence": "review",
        "evidence_json": "{}",
    }])
    service.inspect_video = lambda payload: {
        "source_path": str(new_source.resolve()),
        "source_size_bytes": new_source.stat().st_size,
        "source_mtime_ns": new_source.stat().st_mtime_ns,
        "duration_ms": 30_000,
        "width": 1920,
        "height": 1080,
        "fps": 60.0,
        "video_codec": "hevc",
        "audio_codec": "aac",
    }

    result = service.handle("relink_video", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "video_path": str(new_source),
    })

    assert result["video"]["analysis_invalidated"] is True
    assert store.list_candidates(video["id"]) == []
    assert store.active_roi(video["id"]) is None


def test_statistics_includes_export_totals(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "导出统计", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    store.create_export({
        "project_id": project["id"],
        "output_path": str(tmp_path / "highlights.mp4"),
        "mode": "merge",
        "candidate_count": 2,
        "duration_ms": 12_000,
        "file_size_bytes": 9876,
    })

    statistics = service.handle("get_statistics", {"project_root": str(project_root)})["statistics"]

    assert statistics["export_count"] == 1
    assert statistics["export_duration_ms"] == 12_000
    assert statistics["export_file_size_bytes"] == 9876


def test_start_export_runs_as_recoverable_job(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "异步导出", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    source = tmp_path / "source.mp4"
    source.write_bytes(b"fixture")
    video = store.link_video({
        "source_path": str(source),
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.replace_candidates(video["id"], [{
        "id": "candidate-1", "video_id": video["id"], "event_time_ms": 1_000,
        "default_start_ms": 0, "default_end_ms": 4_000,
        "review_start_ms": 0, "review_end_ms": 4_000,
        "detector_version": "test", "score": 0.8, "confidence": "review",
        "evidence_json": "{}",
    }])
    service._execute_export = lambda payload, **_kwargs: {
        "export": {"id": "export-1"},
        "files": ["/tmp/highlights.mp4"],
    }

    started = service.handle("start_export", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "mode": "merge",
    })
    job_id = started["job"]["id"]
    deadline = time.time() + 2
    while time.time() < deadline:
        job = store.get_job(job_id)
        if job and job["state"] in {"completed", "failed", "cancelled"}:
            break
        time.sleep(0.02)

    job = store.get_job(job_id)
    assert job is not None
    assert job["state"] == "completed"
    assert job["progress"] == pytest.approx(1.0)


def test_completed_export_keeps_retry_parameters_in_checkpoint(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "导出参数", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    source = tmp_path / "source.mp4"
    source.write_bytes(b"fixture")
    video = store.link_video({
        "source_path": str(source),
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.replace_candidates(video["id"], [{
        "id": "candidate-1", "video_id": video["id"], "event_time_ms": 1_000,
        "default_start_ms": 0, "default_end_ms": 4_000,
        "review_start_ms": 0, "review_end_ms": 4_000,
        "detector_version": "test", "evidence_json": "{}",
    }])
    player = store.create_player("#1")
    store.set_candidate_player("candidate-1", player["id"])
    service._execute_export = lambda payload, **_kwargs: {
        "export": {"id": "export-1"},
        "files": ["/tmp/highlights.mp4"],
    }

    started = service.handle("start_export", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "mode": "merge",
        "output_path": str(tmp_path / "highlights.mp4"),
        "player_ids": [player["id"]],
        "include_unassigned": False,
    })
    job_id = started["job"]["id"]
    service._job_threads[job_id].join(timeout=2)

    checkpoint = json.loads(store.get_job(job_id)["checkpoint_json"])
    assert checkpoint["mode"] == "merge"
    assert checkpoint["output_path"] == str(tmp_path / "highlights.mp4")
    assert checkpoint["player_ids"] == [player["id"]]
    assert checkpoint["include_unassigned"] is False
    assert checkpoint["export"] == {"id": "export-1"}
    assert checkpoint["files"] == ["/tmp/highlights.mp4"]


def test_list_candidates_returns_original_video_even_when_proxy_exists(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "代理审核", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    proxy = project_root / "artifacts" / "proxies" / "review.mp4"
    proxy.write_bytes(b"proxy")
    project = store.project()
    assert project is not None
    job = store.create_job(project["id"], video["id"], "analysis")
    store.update_job(
        job["id"],
        state="completed",
        stage="persist_candidates",
        progress=1.0,
        checkpoint={"proxy_video": str(proxy)},
    )

    result = service.handle(
        "list_candidates",
        {"project_root": str(project_root), "video_id": video["id"]},
    )

    assert result["candidates"] == []
    assert result["review_video_path"] == str(Path(video["source_path"]).resolve())


def test_open_project_rejects_missing_project_without_creating_files(tmp_path: Path):
    project_root = tmp_path / "missing-project"
    with pytest.raises(ProtocolError) as error:
        EngineService().handle("open_project", {"project_root": str(project_root)})

    assert error.value.code == "PROJECT_NOT_FOUND"
    assert not project_root.exists()


def test_list_recent_projects_scans_only_explicit_root_children(tmp_path: Path):
    projects_root = tmp_path / "projects"
    first_root = projects_root / "first"
    second_root = projects_root / "second"
    nested_root = projects_root / "nested" / "hidden"
    outside_root = tmp_path / "outside"
    service = EngineService()
    service.handle("create_project", {"name": "项目一", "root_path": str(first_root)})
    service.handle("create_project", {"name": "项目二", "root_path": str(second_root)})
    service.handle("create_project", {"name": "嵌套项目", "root_path": str(nested_root)})
    service.handle("create_project", {"name": "外部项目", "root_path": str(outside_root)})

    result = service.handle(
        "list_recent_projects",
        {"roots": [str(projects_root)], "limit": 10},
    )

    roots = {item["project_root"] for item in result["projects"]}
    assert roots == {str(first_root.resolve()), str(second_root.resolve())}
    assert str(nested_root.resolve()) not in roots
    assert str(outside_root.resolve()) not in roots
    assert result["scanned_roots"] == [str(projects_root.resolve())]


def test_list_recent_projects_requires_explicit_roots():
    with pytest.raises(ProtocolError) as error:
        EngineService().handle("list_recent_projects", {})

    assert error.value.code == "INVALID_REQUEST"


def test_roi_is_required_before_analysis(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "测试项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video(
        {
            "source_path": str(tmp_path / "source.mp4"),
            "source_size_bytes": 1,
            "source_mtime_ns": 1,
            "duration_ms": 1000,
            "width": 960,
            "height": 720,
            "fps": 30.0,
            "video_codec": "h264",
            "audio_codec": "aac",
        }
    )
    payload = {"project_root": str(project_root), "video_id": video["id"]}
    try:
        service._create_analysis_job(payload)
    except Exception as exc:
        assert "ROI" in str(exc)
    else:
        raise AssertionError("analysis must require ROI")
    service.handle("save_roi", {**payload, "x1": 10, "y1": 20, "x2": 100, "y2": 120})
    job = service._create_analysis_job(payload)["job"]
    assert job["state"] == "queued"


def test_create_analysis_job_persists_custom_clip_window(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "片段时长", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video(
        {
            "source_path": str(tmp_path / "source.mp4"),
            "source_size_bytes": 1,
            "source_mtime_ns": 1,
            "duration_ms": 20_000,
            "width": 960,
            "height": 720,
            "fps": 30.0,
            "video_codec": "h264",
            "audio_codec": "aac",
        }
    )
    store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})

    job = service._create_analysis_job(
        {
            "project_root": str(project_root),
            "video_id": video["id"],
            "before_seconds": 5,
            "after_seconds": 4,
        }
    )["job"]

    checkpoint = json.loads(store.get_job(job["id"])["checkpoint_json"])
    assert checkpoint["before_seconds"] == 5
    assert checkpoint["after_seconds"] == 4


def test_extract_preview_generates_frame_and_reuses_cached_frame(tmp_path: Path, monkeypatch):
    source = tmp_path / "source.mp4"
    subprocess.run(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10",
            "-t", "1", "-pix_fmt", "yuv420p", str(source),
        ],
        check=True,
    )
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "测试项目", "root_path": str(project_root)})
    video = service.handle(
        "link_video", {"project_root": str(project_root), "video_path": str(source)}
    )["video"]

    result = service.handle(
        "extract_preview",
        {"project_root": str(project_root), "video_id": video["id"], "time_ms": 200},
    )

    assert result["time_ms"] == 200
    assert Path(result["path"]).is_file()

    def fail_if_called(*args, **kwargs):
        raise AssertionError("cached preview should not invoke ffmpeg")

    monkeypatch.setattr("basketball_engine.service.subprocess.run", fail_if_called)
    cached = service.handle(
        "extract_preview",
        {"project_root": str(project_root), "video_id": video["id"], "time_ms": 200},
    )
    assert cached == result


def test_persist_candidates_creates_pending_reviews(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "测试项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    roi = store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    row = {
        "id": "candidate-1",
        "video_id": video["id"],
        "roi_id": roi["id"],
        "event_time_ms": 1000,
        "default_start_ms": 0,
        "default_end_ms": 4000,
        "review_start_ms": 0,
        "review_end_ms": 4000,
        "detector_version": "test",
        "score": 0.8,
        "confidence": "review",
        "evidence_json": "{}",
    }
    store.replace_candidates(video["id"], [row])
    candidates = store.list_candidates(video["id"])
    assert candidates[0]["id"] == "candidate-1"
    assert candidates[0]["review_status"] == "pending"


def test_create_manual_candidate_is_included_and_survives_reanalysis(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "手动片段", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 60_000,
        "width": 960,
        "height": 720,
    })

    created = service.handle("create_manual_candidate", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "start_ms": 12_000,
        "end_ms": 21_000,
        "event_time_ms": 16_000,
    })["candidate"]

    assert created["detector_version"] == "manual-v1"
    assert created["confidence"] == "manual"
    assert created["selection_status"] == "included"

    store.replace_candidates(video["id"], [{
        "id": "detected-1",
        "video_id": video["id"],
        "event_time_ms": 30_000,
        "default_start_ms": 24_000,
        "default_end_ms": 33_000,
        "review_start_ms": 24_000,
        "review_end_ms": 33_000,
        "detector_version": "test",
        "confidence": "review",
        "evidence_json": "{}",
    }])

    candidates = store.list_candidates(video["id"])
    assert {candidate["id"] for candidate in candidates} == {
        created["id"],
        "detected-1",
    }


def test_list_candidates_exposes_default_included_selection(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "默认保留", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.replace_candidates(video["id"], [{
        "id": "included-candidate",
        "video_id": video["id"],
        "event_time_ms": 1000,
        "default_start_ms": 0,
        "default_end_ms": 4000,
        "review_start_ms": 0,
        "review_end_ms": 4000,
        "detector_version": "test",
        "score": 0.9,
        "confidence": "high",
        "evidence_json": "{}",
    }])

    candidate = store.list_candidates(video["id"])[0]

    assert candidate["selection_status"] == "included"


def test_review_candidate_persists_reason_for_excluded_candidate(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "审核原因", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    row = {
        "id": "candidate-reason",
        "video_id": video["id"],
        "event_time_ms": 1000,
        "default_start_ms": 0,
        "default_end_ms": 4000,
        "review_start_ms": 0,
        "review_end_ms": 4000,
        "detector_version": "test",
        "score": 0.4,
        "confidence": "review",
        "evidence_json": "{}",
    }
    store.replace_candidates(video["id"], [row])

    service.handle("review_candidate", {
        "project_root": str(project_root),
        "candidate_id": row["id"],
        "status": "excluded",
        "reason": "rebound",
        "note": "篮板反弹",
    })

    candidate = store.list_candidates(video["id"])[0]
    assert candidate["review_status"] == "excluded"
    assert candidate["review_reason"] == "rebound"
    assert candidate["note"] == "篮板反弹"


def test_review_candidate_rejects_unknown_reason(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "审核原因校验", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    row = {
        "id": "candidate-invalid-reason",
        "video_id": video["id"],
        "event_time_ms": 1000,
        "default_start_ms": 0,
        "default_end_ms": 4000,
        "review_start_ms": 0,
        "review_end_ms": 4000,
        "detector_version": "test",
        "score": 0.4,
        "confidence": "review",
        "evidence_json": "{}",
    }
    store.replace_candidates(video["id"], [row])

    with pytest.raises(ProtocolError) as error:
        service.handle("review_candidate", {
            "project_root": str(project_root),
            "candidate_id": row["id"],
            "status": "excluded",
            "reason": "not-a-review-reason",
        })

    assert error.value.code == "INVALID_REQUEST"


def test_list_review_history_returns_all_review_actions(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "审核历史", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    row = {
        "id": "candidate-history",
        "video_id": video["id"],
        "event_time_ms": 1000,
        "default_start_ms": 0,
        "default_end_ms": 4000,
        "review_start_ms": 0,
        "review_end_ms": 4000,
        "detector_version": "test",
        "score": 0.4,
        "confidence": "review",
        "evidence_json": "{}",
    }
    store.replace_candidates(video["id"], [row])
    review_payload = {
        "project_root": str(project_root),
        "candidate_id": row["id"],
    }
    service.handle("review_candidate", {
        **review_payload,
        "status": "deferred",
        "reason": "uncertain",
    })
    service.handle("review_candidate", {
        **review_payload,
        "status": "excluded",
        "reason": "rebound",
    })

    result = service.handle("list_review_history", review_payload)

    assert [item["status"] for item in result["history"]] == ["deferred", "excluded"]
    assert result["history"][0]["reason"] == "uncertain"


def test_start_analysis_records_model_failure_without_blocking_request(tmp_path: Path):
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
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    payload = {
        "project_root": str(project_root),
        "video_id": video["id"],
        "model_path": str(tmp_path / "missing.pt"),
    }
    job = service.handle("start_analysis", payload)["job"]
    for _ in range(20):
        current = service.handle("get_job", {"project_root": str(project_root), "job_id": job["id"]})["job"]
        if current["state"] == "failed":
            break
        time.sleep(0.02)
    assert current["state"] == "failed"
    assert current["error_code"] == "MODEL_LOAD_FAILED"


def test_start_analysis_rejects_second_heavy_job(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "测试项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    model = tmp_path / "model.pt"
    model.write_bytes(b"test")
    started = threading.Event()
    release = threading.Event()

    def blocked_run(_payload, _job_id):
        started.set()
        release.wait(timeout=2)

    service._run_analysis = blocked_run
    payload = {
        "project_root": str(project_root),
        "video_id": video["id"],
        "model_path": str(model),
    }
    service.handle("start_analysis", payload)
    assert started.wait(timeout=1)
    with pytest.raises(ProtocolError, match="已有重型任务正在运行"):
        service.handle("start_analysis", payload)
    release.set()
    for thread in list(service._job_threads.values()):
        thread.join(timeout=1)


def test_cancel_job_persists_cancelled_state(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "测试项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    job = service._create_analysis_job({
        "project_root": str(project_root), "video_id": video["id"],
    })["job"]
    cancelled = service.handle("cancel_job", {
        "project_root": str(project_root), "job_id": job["id"],
    })["job"]
    assert cancelled["state"] == "cancelled"
    assert cancelled["error_code"] == "JOB_CANCELLED"


def test_terminal_job_state_cannot_be_overwritten_by_late_progress(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "终态保护", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    job = store.create_job(project["id"], None, "analysis")
    store.update_job(job["id"], state="completed", stage="persist_candidates", progress=1.0)

    late = store.update_job(job["id"], state="running", stage="coarse_scan", progress=0.4)

    assert late["state"] == "completed"
    assert late["stage"] == "persist_candidates"
    assert late["progress"] == 1.0


def test_cancel_live_job_reports_cancelling_until_worker_stops(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "测试项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    project = store.project()
    assert project is not None
    job = store.create_job(project["id"], None, "analysis")
    service._job_cancel_events[job["id"]] = threading.Event()

    cancelling = service.handle("cancel_job", {
        "project_root": str(project_root), "job_id": job["id"],
    })["job"]

    assert cancelling["state"] == "queued"
    assert cancelling["stage"] == "cancelling"
    assert service._job_cancel_events[job["id"]].is_set()


def test_unexpected_analysis_error_is_persisted_as_failed(tmp_path: Path, monkeypatch):
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
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    model = tmp_path / "model.pt"
    model.write_bytes(b"test")

    def fail_pipeline(*_args, **_kwargs):
        raise RuntimeError("unexpected pipeline failure")

    monkeypatch.setattr("engine.python.basketball_engine.service.run_pipeline", fail_pipeline)
    payload = {
        "project_root": str(project_root),
        "video_id": video["id"],
        "model_path": str(model),
    }
    job = service.handle("start_analysis", payload)["job"]
    for _ in range(50):
        current = service.handle("get_job", {"project_root": str(project_root), "job_id": job["id"]})["job"]
        if current["state"] == "failed":
            break
        time.sleep(0.02)
    assert current["state"] == "failed"
    assert current["error_code"] == "ANALYSIS_FAILED"
    assert "unexpected pipeline failure" in current["error_message"]


def _analysis_fixture(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "分析闭环", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    source = tmp_path / "source.mp4"
    source.write_bytes(b"fixture")
    video = store.link_video({
        "source_path": str(source),
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    roi = store.save_roi(video["id"], {"x1": 10, "y1": 20, "x2": 100, "y2": 120})
    old = {
        "id": "old-analysis-candidate",
        "video_id": video["id"],
        "roi_id": roi["id"],
        "event_time_ms": 1_000,
        "default_start_ms": 0,
        "default_end_ms": 4_000,
        "review_start_ms": 0,
        "review_end_ms": 4_000,
        "detector_version": "test",
        "evidence_json": "{}",
    }
    store.replace_candidates(video["id"], [old])
    store.review_candidate(old["id"], "goal", "已确认")
    model = tmp_path / "model.pt"
    model.write_bytes(b"model")
    return service, store, video, model


def test_fast_analysis_uses_coarse_candidates_and_persists_timing_checkpoint(
    tmp_path: Path,
    monkeypatch,
):
    service, store, video, model = _analysis_fixture(tmp_path)
    captured = {}

    def fake_build(**kwargs):
        captured.update(kwargs)
        return [["fake", "proxy"], ["fake", "scan"], ["fake", "candidates"]]

    def fake_run(commands, refined_output, *_args, **kwargs):
        assert len(commands) == 3
        assert len(kwargs["stage_outputs"]) == 3
        Path(captured["coarse_detections"]).parent.mkdir(parents=True, exist_ok=True)
        Path(captured["coarse_detections"]).write_text(
            json.dumps({"records": [{"detections": [{"name": "ball"}]}]}),
            encoding="utf-8",
        )
        Path(refined_output).write_text(
            json.dumps({"candidates": [{"time": 1.5, "score": 0.8}]}),
            encoding="utf-8",
        )
        return {
            "refined": {"candidates": [{"time": 1.5, "score": 0.8}]},
            "logs": [],
            "cache_hits": 2,
            "stage_timings_ms": {"prepare_proxy": 11, "coarse_scan": 22, "generate_candidates": 3},
        }

    monkeypatch.setattr("engine.python.basketball_engine.service.build_pipeline_commands", fake_build)
    monkeypatch.setattr("engine.python.basketball_engine.service.run_pipeline", fake_run)
    monkeypatch.setattr(
        service,
        "_prepare_candidate_previews",
        lambda **_: {"generated": 1, "reused": 0, "failed": 0},
    )
    job = service._create_analysis_job({
        "project_root": str(store.root),
        "video_id": video["id"],
        "model_path": str(model),
        "mode": "fast",
    })["job"]

    service._run_analysis(
        {
            "project_root": str(store.root),
            "video_id": video["id"],
            "model_path": str(model),
            "mode": "fast",
        },
        job["id"],
    )

    finished = store.get_job(job["id"])
    assert finished is not None
    assert finished["state"] == "completed"
    checkpoint = json.loads(finished["checkpoint_json"])
    assert checkpoint["mode"] == "fast"
    assert checkpoint["analysis_parameters"]["proxy_width"] == 640
    assert checkpoint["analysis_parameters"]["proxy_height"] == 480
    assert checkpoint["analysis_parameters"]["proxy_fps"] == 3.0
    assert checkpoint["cache_hits"] == 2
    assert checkpoint["total_elapsed_ms"] >= 0
    assert "prepare_review_previews" in checkpoint["stage_timings_ms"]
    assert "persist_candidates" in checkpoint["stage_timings_ms"]
    candidate = store.list_candidates(video["id"])[0]
    assert json.loads(candidate["evidence_json"])["analysis_source"] == "coarse"
    assert candidate["review_status"] == "goal"
    assert candidate["note"] == "已确认"


def test_analysis_failure_keeps_previous_candidates_and_records_elapsed_time(
    tmp_path: Path,
    monkeypatch,
):
    service, store, video, model = _analysis_fixture(tmp_path)

    def fail_pipeline(*_args, **_kwargs):
        raise RuntimeError("pipeline failed")

    monkeypatch.setattr("engine.python.basketball_engine.service.run_pipeline", fail_pipeline)
    job = service._create_analysis_job({
        "project_root": str(store.root),
        "video_id": video["id"],
        "model_path": str(model),
        "mode": "fast",
    })["job"]
    service._run_analysis(
        {
            "project_root": str(store.root),
            "video_id": video["id"],
            "model_path": str(model),
            "mode": "fast",
        },
        job["id"],
    )

    finished = store.get_job(job["id"])
    assert finished is not None
    assert finished["state"] == "failed"
    assert "pipeline failed" in finished["error_message"]
    checkpoint = json.loads(finished["checkpoint_json"])
    assert checkpoint["total_elapsed_ms"] >= 0
    candidates = store.list_candidates(video["id"])
    assert [candidate["id"] for candidate in candidates] == ["old-analysis-candidate"]
    assert candidates[0]["review_status"] == "goal"


def test_analysis_cancel_keeps_previous_candidates(tmp_path: Path, monkeypatch):
    service, store, video, model = _analysis_fixture(tmp_path)
    captured = {}

    def fake_build(**kwargs):
        captured.update(kwargs)
        return [["fake", "proxy"], ["fake", "scan"], ["fake", "candidates"]]

    def fake_run(_commands, refined_output, *_args, **kwargs):
        Path(captured["coarse_detections"]).parent.mkdir(parents=True, exist_ok=True)
        Path(captured["coarse_detections"]).write_text(
            json.dumps({"records": [{"detections": [{"name": "ball"}]}]}),
            encoding="utf-8",
        )
        Path(refined_output).write_text(
            json.dumps({"candidates": [{"time": 2.0, "score": 0.8}]}),
            encoding="utf-8",
        )
        return {"refined": {"candidates": [{"time": 2.0, "score": 0.8}]}, "logs": [], "stage_timings_ms": {}}

    monkeypatch.setattr("engine.python.basketball_engine.service.build_pipeline_commands", fake_build)
    monkeypatch.setattr("engine.python.basketball_engine.service.run_pipeline", fake_run)
    job = service._create_analysis_job({
        "project_root": str(store.root),
        "video_id": video["id"],
        "model_path": str(model),
        "mode": "fast",
    })["job"]
    cancel_event = threading.Event()
    service._job_cancel_events[job["id"]] = cancel_event
    monkeypatch.setattr(
        service,
        "_prepare_candidate_previews",
        lambda **_: (cancel_event.set() or {"generated": 0, "reused": 0, "failed": 0}),
    )

    service._run_analysis(
        {
            "project_root": str(store.root),
            "video_id": video["id"],
            "model_path": str(model),
            "mode": "fast",
        },
        job["id"],
    )

    finished = store.get_job(job["id"])
    assert finished is not None
    assert finished["state"] == "cancelled"
    candidates = store.list_candidates(video["id"])
    assert [candidate["id"] for candidate in candidates] == ["old-analysis-candidate"]


def test_engine_rejects_invalid_roi(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "测试项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    with pytest.raises(ProtocolError, match="ROI"):
        service.handle("save_roi", {
            "project_root": str(project_root), "video_id": video["id"],
            "x1": 100, "y1": 20, "x2": 10, "y2": 120,
        })


def test_engine_rejects_roi_that_only_contains_the_rim(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "检测区域校验", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })

    with pytest.raises(ProtocolError, match="ROI_TOO_SMALL"):
        service.handle("save_roi", {
            "project_root": str(project_root),
            "video_id": video["id"],
            "x1": 480,
            "y1": 315,
            "x2": 500,
            "y2": 335,
        })


def test_protocol_rejects_non_string_request_id():
    with pytest.raises(ProtocolError, match="request_id"):
        parse_request(json.dumps({
            "protocol_version": "1.0",
            "type": "request",
            "request_id": 123,
            "command": "hello",
            "payload": {},
        }))


def test_replace_candidates_preserves_existing_review_for_stable_id(tmp_path: Path):
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "测试项目", "root_path": str(project_root)})
    store = ProjectStore(project_root)
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
        "fps": 30.0,
        "video_codec": "h264",
        "audio_codec": "aac",
    })
    row = {
        "id": "candidate-stable", "video_id": video["id"], "event_time_ms": 1000,
        "default_start_ms": 0, "default_end_ms": 4000,
        "review_start_ms": 0, "review_end_ms": 4000,
        "detector_version": "test", "score": 0.8, "confidence": "review",
        "evidence_json": "{}",
    }
    store.replace_candidates(video["id"], [row])
    store.review_candidate(row["id"], "goal", "确认")
    store.replace_candidates(video["id"], [row])
    candidate = store.list_candidates(video["id"])[0]
    assert candidate["review_status"] == "goal"
    assert candidate["note"] == "确认"


def test_analysis_mode_defaults_to_standard_and_is_persisted_per_project(tmp_path: Path):
    store = ProjectStore(tmp_path / "project")
    store.initialize()
    store.create_project("project-1", "模式测试")

    assert store.analysis_mode() == "standard"
    store.set_analysis_mode("fast")
    assert store.analysis_mode() == "fast"
    assert store.context()["analysis_mode"] == "fast"


def test_replace_candidates_inherits_review_from_nearby_event_and_shifts_manual_range(tmp_path: Path):
    store = ProjectStore(tmp_path / "project")
    store.initialize()
    store.create_project("project-1", "继承测试")
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 30_000,
        "width": 960,
        "height": 720,
    })
    old = {
        "id": "old-candidate", "video_id": video["id"], "roi_id": None,
        "event_time_ms": 10_000, "default_start_ms": 4_000,
        "default_end_ms": 13_000, "review_start_ms": 3_000,
        "review_end_ms": 14_000, "detector_version": "test",
        "evidence_json": "{}",
    }
    store.replace_candidates(video["id"], [old])
    store.review_candidate(old["id"], "goal", "手动确认", "made")
    store.set_candidate_player(old["id"], "player-1") if False else None

    new = {
        **old,
        "id": "new-candidate",
        "event_time_ms": 11_000,
        "default_start_ms": 5_000,
        "default_end_ms": 14_000,
        "review_start_ms": 5_000,
        "review_end_ms": 14_000,
    }
    store.replace_candidates(video["id"], [new])
    candidate = store.list_candidates(video["id"])[0]

    assert candidate["review_status"] == "goal"
    assert candidate["review_reason"] == "made"
    assert candidate["note"] == "手动确认"
    assert candidate["review_start_ms"] == 4_000
    assert candidate["review_end_ms"] == 15_000
    assert candidate["reviewed_at"] is None
    assert candidate["review_duration_ms"] is None


def test_replace_candidates_clamps_inherited_manual_range_to_video_duration(tmp_path: Path):
    store = ProjectStore(tmp_path / "project")
    store.initialize()
    store.create_project("project-1", "边界继承测试")
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 10_000,
        "width": 960,
        "height": 720,
    })
    old = {
        "id": "old-boundary", "video_id": video["id"], "roi_id": None,
        "event_time_ms": 8_500, "default_start_ms": 6_000,
        "default_end_ms": 9_500, "review_start_ms": 8_000,
        "review_end_ms": 9_900, "detector_version": "test",
        "evidence_json": "{}",
    }
    store.replace_candidates(video["id"], [old])
    store.review_candidate(old["id"], "goal")

    new = {
        **old,
        "id": "new-boundary",
        "event_time_ms": 9_500,
        "default_start_ms": 7_000,
        "default_end_ms": 10_000,
        "review_start_ms": 7_000,
        "review_end_ms": 10_000,
    }
    store.replace_candidates(video["id"], [new])
    candidate = store.list_candidates(video["id"])[0]

    assert candidate["review_status"] == "goal"
    assert candidate["review_start_ms"] == 9_000
    assert candidate["review_end_ms"] == 10_000


def test_replace_candidates_does_not_reuse_exact_match_review_for_nearby_candidate(tmp_path: Path):
    store = ProjectStore(tmp_path / "project")
    store.initialize()
    store.create_project("project-1", "继承唯一性测试")
    video = store.link_video({
        "source_path": str(tmp_path / "source.mp4"),
        "source_size_bytes": 1,
        "source_mtime_ns": 1,
        "duration_ms": 20_000,
        "width": 960,
        "height": 720,
    })
    old = {
        "id": "exact-old", "video_id": video["id"], "roi_id": None,
        "event_time_ms": 5_000, "default_start_ms": 4_000,
        "default_end_ms": 6_000, "review_start_ms": 4_000,
        "review_end_ms": 6_000, "detector_version": "test",
        "evidence_json": "{}",
    }
    store.replace_candidates(video["id"], [old])
    store.review_candidate(old["id"], "goal")

    exact = {**old}
    nearby = {
        **old,
        "id": "nearby-new",
        "event_time_ms": 5_500,
    }
    store.replace_candidates(video["id"], [exact, nearby])
    candidates = {item["id"]: item for item in store.list_candidates(video["id"])}

    assert candidates["exact-old"]["review_status"] == "goal"
    assert candidates["nearby-new"]["review_status"] == "pending"


def test_list_candidates_returns_original_video_for_review(tmp_path: Path):
    project_root = tmp_path / "project"
    source = tmp_path / "source.mp4"
    subprocess.run(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10",
            "-t", "1", "-pix_fmt", "yuv420p", str(source),
        ],
        check=True,
    )
    service = EngineService()
    service.handle("create_project", {"name": "原视频审核", "root_path": str(project_root)})
    video = service.handle("link_video", {
        "project_root": str(project_root), "video_path": str(source),
    })["video"]

    result = service.handle("list_candidates", {
        "project_root": str(project_root), "video_id": video["id"],
    })

    assert result["review_video_path"] == str(source.resolve())


def test_start_export_uses_only_goal_reviews(tmp_path: Path):
    source = tmp_path / "source.mp4"
    subprocess.run(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10",
            "-t", "2", "-pix_fmt", "yuv420p", str(source),
        ],
        check=True,
    )
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "测试项目", "root_path": str(project_root)})
    video = service.handle("link_video", {"project_root": str(project_root), "video_path": str(source)})["video"]
    store = ProjectStore(project_root)
    rows = [
        {
            "id": "goal-1", "video_id": video["id"], "event_time_ms": 1000,
            "default_start_ms": 0, "default_end_ms": 1500,
            "review_start_ms": 0, "review_end_ms": 1500,
            "detector_version": "test", "score": 0.9, "confidence": "high",
            "evidence_json": "{}",
        },
        {
            "id": "excluded-1", "video_id": video["id"], "event_time_ms": 1700,
            "default_start_ms": 1000, "default_end_ms": 2000,
            "review_start_ms": 1000, "review_end_ms": 2000,
            "detector_version": "test", "score": 0.3, "confidence": "review",
            "evidence_json": "{}",
        },
    ]
    store.replace_candidates(video["id"], rows)
    service.handle("review_candidate", {"project_root": str(project_root), "candidate_id": "goal-1", "status": "goal"})
    service.handle("review_candidate", {"project_root": str(project_root), "candidate_id": "excluded-1", "status": "excluded"})

    started = service.handle("start_export", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "mode": "separate",
        "output_dir": str(tmp_path / "exports"),
    })
    service._job_threads[started["job"]["id"]].join(timeout=10)
    job = store.get_job(started["job"]["id"])
    project = store.project()
    exports = store.list_exports(project["id"]) if project else []

    assert job is not None
    assert job["state"] == "completed"
    assert exports[0]["candidate_count"] == 1
    assert len(exports[0]["metadata"]["files"]) == 1
    assert Path(exports[0]["metadata"]["files"][0]).is_file()


def test_start_export_includes_unreviewed_candidates_by_default(tmp_path: Path):
    source = tmp_path / "source.mp4"
    subprocess.run(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10",
            "-t", "2", "-pix_fmt", "yuv420p", str(source),
        ],
        check=True,
    )
    project_root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "默认采纳", "root_path": str(project_root)})
    video = service.handle("link_video", {"project_root": str(project_root), "video_path": str(source)})["video"]
    store = ProjectStore(project_root)
    rows = [
        {
            "id": "included-1", "video_id": video["id"], "event_time_ms": 500,
            "default_start_ms": 0, "default_end_ms": 900,
            "review_start_ms": 0, "review_end_ms": 900,
            "detector_version": "test", "score": 0.9, "confidence": "high",
            "evidence_json": "{}",
        },
        {
            "id": "excluded-1", "video_id": video["id"], "event_time_ms": 1200,
            "default_start_ms": 700, "default_end_ms": 1800,
            "review_start_ms": 700, "review_end_ms": 1800,
            "detector_version": "test", "score": 0.3, "confidence": "review",
            "evidence_json": "{}",
        },
    ]
    store.replace_candidates(video["id"], rows)
    service.handle("review_candidate", {
        "project_root": str(project_root),
        "candidate_id": "excluded-1",
        "status": "excluded",
    })

    started = service.handle("start_export", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "mode": "separate",
        "output_dir": str(tmp_path / "exports"),
    })
    service._job_threads[started["job"]["id"]].join(timeout=10)
    job = store.get_job(started["job"]["id"])
    project = store.project()
    exports = store.list_exports(project["id"]) if project else []

    assert job is not None
    assert job["state"] == "completed"
    assert exports[0]["candidate_count"] == 1
    assert Path(exports[0]["metadata"]["files"][0]).is_file()


def test_coarse_overlay_uses_nearest_ball_independent_of_detection_order():
    match = {
        "time": 10.0,
        "above": {"time": 9.9, "x": 100.0, "y": 50.0},
        "below": {"time": 10.2, "x": 115.0, "y": 100.0},
    }
    rim = {"center_x": 110.0, "rim_y": 80.0, "width": 40.0, "height": 20.0}
    records = [
        {
            "time": 10.0,
            "detections": [
                {"name": "ball", "center": [190.0, 55.0]},
                {"name": "ball", "center": [105.0, 55.0]},
            ],
        },
        {
            "time": 10.1,
            "detections": [{"name": "ball", "center": [110.0, 75.0]}],
        },
    ]

    far_first = EngineService._coarse_overlay(match, rim, 1.0, records)
    records[0]["detections"].reverse()
    near_first = EngineService._coarse_overlay(match, rim, 1.0, records)

    assert far_first["trajectory"] == near_first["trajectory"]
    assert far_first["trajectory"][1]["x"] == 105.0


def test_tracking_association_has_a_new_consistent_algorithm_version():
    assert ANALYSIS_ALGORITHM_VERSION == "python-v2.14-white-net-trajectory"
    assert refine_dynamic_candidates.ALGORITHM_VERSION == ANALYSIS_ALGORITHM_VERSION


def test_coarse_overlay_rejects_incomplete_crossing_points():
    overlay = EngineService._coarse_overlay(
        {
            "time": 10.0,
            "above": {"time": 9.9, "y": 50.0},
            "below": {"time": 10.2, "x": 115.0, "y": 100.0},
        },
        {"center_x": 110.0, "rim_y": 80.0, "width": 40.0, "height": 20.0},
        1.0,
        [],
    )

    assert overlay is None
