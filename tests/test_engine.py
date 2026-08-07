import json
import subprocess
import sys
import time
import threading
from pathlib import Path

import pytest

from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore
from engine.python.basketball_engine.protocol import ProtocolError, parse_request


def test_create_project_and_statistics(tmp_path: Path):
    service = EngineService()
    result = service.handle("create_project", {"name": "测试项目", "root_path": str(tmp_path / "project")})
    assert result["project"]["name"] == "测试项目"

    stats = service.handle("get_statistics", {"project_root": str(tmp_path / "project")})
    assert stats["statistics"]["candidate_count"] == 0
    assert stats["statistics"]["goal_count"] == 0


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
    job = service.handle("create_analysis_job", {
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
    job = service.handle("create_analysis_job", {
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
    job = service.handle("create_analysis_job", {
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
    service._execute_export = lambda payload, progress_callback=None: {
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


def test_list_candidates_returns_latest_existing_proxy_for_review(tmp_path: Path):
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
    assert result["review_video_path"] == str(proxy.resolve())


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
        service.handle("create_analysis_job", payload)
    except Exception as exc:
        assert "ROI" in str(exc)
    else:
        raise AssertionError("analysis must require ROI")
    service.handle("save_roi", {**payload, "x1": 10, "y1": 20, "x2": 100, "y2": 120})
    job = service.handle("create_analysis_job", payload)["job"]
    assert job["state"] == "queued"


def test_create_proxy_generates_reusable_artifact(tmp_path: Path):
    source = tmp_path / "source.mp4"
    subprocess.run(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "color=c=black:s=320x240:r=10",
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
        "create_proxy",
        {
            "project_root": str(project_root),
            "video_id": video["id"],
            "width": 160,
            "height": 120,
            "fps": 5,
        },
    )

    assert Path(result["artifact"]["path"]).is_file()
    assert result["job"]["state"] == "completed"
    assert not list((project_root / "artifacts" / "proxies").glob("*.part*"))

    cached = service.handle(
        "create_proxy",
        {
            "project_root": str(project_root),
            "video_id": video["id"],
            "width": 160,
            "height": 120,
            "fps": 5,
        },
    )
    assert cached["artifact"]["cache_hit"] is True


def test_extract_preview_generates_frame(tmp_path: Path):
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


def test_start_analysis_records_model_failure_without_blocking_request(tmp_path: Path):
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
    job = service.handle("create_analysis_job", {
        "project_root": str(project_root), "video_id": video["id"],
    })["job"]
    cancelled = service.handle("cancel_job", {
        "project_root": str(project_root), "job_id": job["id"],
    })["job"]
    assert cancelled["state"] == "cancelled"
    assert cancelled["error_code"] == "JOB_CANCELLED"


def test_unexpected_analysis_error_is_persisted_as_failed(tmp_path: Path, monkeypatch):
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


def test_engine_rejects_invalid_roi_and_proxy_parameters(tmp_path: Path):
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
    with pytest.raises(ProtocolError, match="代理视频参数"):
        service.handle("create_proxy", {
            "project_root": str(project_root), "video_id": video["id"], "fps": "invalid",
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


def test_export_clips_uses_only_goal_reviews(tmp_path: Path):
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

    result = service.handle("export_clips", {
        "project_root": str(project_root),
        "video_id": video["id"],
        "mode": "separate",
        "output_dir": str(tmp_path / "exports"),
    })

    assert result["export"]["candidate_count"] == 1
    assert len(result["files"]) == 1
    assert Path(result["files"][0]).is_file()
