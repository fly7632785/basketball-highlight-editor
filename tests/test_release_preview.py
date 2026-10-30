import copy
import json
import shutil
import threading
from pathlib import Path

import cv2
import numpy as np
import pytest

from engine.python.basketball_engine.protocol import ProtocolError
from engine.python.basketball_engine.release_preview import (
    cached_context,
    estimate_release,
    render_release_previews,
)
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.shooter_review import persist_evidence
from engine.python.basketball_engine.storage import ProjectStore


def tiny_video(path, fps, count, size, color):
    path.parent.mkdir(parents=True, exist_ok=True)
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"MJPG"), fps, size)
    assert writer.isOpened()
    for i in range(count):
        image = np.full((size[1], size[0], 3), color, np.uint8)
        image[:, :, 1] = min(240, i * 4)
        writer.write(image)
    writer.release()


@pytest.fixture
def release_project(tmp_path):
    source = tmp_path / "source.avi"
    tiny_video(source, 30, 240, (320, 240), (10, 20, 210))
    root = tmp_path / "project"
    service = EngineService()
    service.handle("create_project", {"name": "Light preview", "root_path": str(root)})
    store = ProjectStore(root)
    video = store.link_video(
        {
            "source_path": str(source),
            "source_size_bytes": source.stat().st_size,
            "source_mtime_ns": source.stat().st_mtime_ns,
            "width": 320,
            "height": 240,
            "duration_ms": 8000,
            "fps": 30,
        }
    )
    points = [
        {"time": t, "x": x, "y": y}
        for t, x, y in [
            (3.8, 80, 160),
            (4, 90, 115),
            (4.2, 100, 70),
            (4.4, 110, 45),
            (4.6, 115, 40),
            (4.8, 120, 65),
            (5, 120, 100),
        ]
    ]
    row = {
        "id": "shot",
        "video_id": video["id"],
        "event_time_ms": 5000,
        "default_start_ms": 2000,
        "default_end_ms": 6000,
        "review_start_ms": 2000,
        "review_end_ms": 6000,
        "detector_version": "fixture",
        "evidence_json": json.dumps({"overlay": {"trajectory": points}}),
    }
    store.replace_candidates(video["id"], [row])
    proxy = root / "artifacts/proxies/existing.avi"
    tiny_video(proxy, 5, 30, (160, 120), (210, 20, 10))
    checkpoint = {
        "proxy_video": str(proxy),
        "analysis_parameters": {
            "source_path": str(source),
            "source_size_bytes": source.stat().st_size,
            "source_mtime_ns": source.stat().st_mtime_ns,
            "analysis_start_ms": 2000,
        },
    }
    job = store.create_job(store.project()["id"], video["id"], "analysis", checkpoint)[
        "id"
    ]
    store.update_job(job, state="completed")
    try:
        yield service, store, video, row, source, proxy, checkpoint
    finally:
        service.shutdown()


def test_proxy_stills_keep_trim_time_and_source_region_without_detecting_people(
    release_project,
):
    _, store, video, row, source, proxy, _ = release_project
    result = render_release_previews(
        video, source, [row], store.root / "light", "g1", proxy=proxy, offset_ms=2000
    )
    item = result[0]
    assert item["method"] == "ball_release_preview_v1"
    assert item["image_source"] == "analysis_proxy"
    assert item["proxy_frame_size"] == [160, 120]
    assert [f["time_ms"] for f in item["frames"]] == [3800, 4000, 4200]
    for frame in item["frames"]:
        assert frame["focus_region"]["kind"] == "approximate_release_area"
        image = cv2.imread(frame["focus_region"]["crop_path"])
        assert (
            image[:, :, 0].mean() > image[:, :, 2].mean()
        )  # Blue proxy, not red source.
        x1, y1, x2, y2 = frame["focus_region"]["bbox"]
        assert 0 <= x1 < x2 <= 320 and 0 <= y1 < y2 <= 240


def test_missing_launch_evidence_gives_uncertain_wide_frame(release_project):
    _, store, video, row, source, proxy, _ = release_project
    empty = dict(row, evidence_json="{}")
    result = render_release_previews(
        video, source, [empty], store.root / "wide", "g", proxy=proxy, offset_ms=2000
    )[0]
    assert result["release_uncertain"] is True
    assert result["reason"] == "release_not_visible_in_existing_ball_track"
    assert all(f["focus_region"] is None for f in result["frames"])
    assert (
        estimate_release(row, [{"time": 4, "x": 10, "y": 10}], 320, 240)["bbox"] is None
    )


def test_rim_bounce_does_not_replace_the_original_release():
    candidate = {"event_time_ms": 5000, "evidence_json": "{}"}
    points = [
        {"time": t, "x": 100 + (t - 4) * 10, "y": 20 + 150 * (t - 4) ** 2}
        for t in (4.3, 4.4, 4.5, 4.6, 4.7)
    ]
    points.extend(
        [
            {"time": 4.8, "x": 110, "y": 50},
            {"time": 4.9, "x": 110, "y": 35},
            {"time": 5, "x": 110, "y": 40},
        ]
    )
    release = estimate_release(candidate, points, 320, 240)
    assert 3000 < release["time_ms"] < 4000
    assert release["reason"] == "existing_ball_flight_backprojection"
    assert release["bbox"] is not None


def test_cached_proxy_must_match_source_and_stay_in_project(release_project, tmp_path):
    _, store, video, _, source, proxy, checkpoint = release_project
    assert cached_context(store, video, source)["proxy"] == proxy
    wrong = copy.deepcopy(checkpoint)
    wrong["analysis_parameters"]["source_mtime_ns"] += 1
    job = store.create_job(store.project()["id"], video["id"], "analysis", wrong)["id"]
    store.update_job(job, state="completed")
    assert (
        cached_context(store, video, source)["proxy"] == proxy
    )  # Skip mismatched newer cache.
    proxy.unlink()
    outside = tmp_path / "outside.avi"
    tiny_video(outside, 5, 10, (160, 120), (0, 0, 0))
    valid_but_outside = copy.deepcopy(checkpoint)
    valid_but_outside["proxy_video"] = str(outside)
    job = store.create_job(
        store.project()["id"], video["id"], "analysis", valid_but_outside
    )["id"]
    store.update_job(job, state="completed")
    assert cached_context(store, video, source)["proxy"] == source


def test_refresh_uses_cached_ball_results_without_starting_any_detector(
    release_project, monkeypatch
):
    service, store, video, _, _, _, _ = release_project

    def no_process(*args, **kwargs):
        raise AssertionError("Light preview must not start inference")

    monkeypatch.setattr("subprocess.Popen", no_process)
    job_id = service.handle(
        "prepare_shooter_review", {"project_root": str(store.root)}
    )["job"]["id"]
    for thread in list(service._job_threads.values()):
        thread.join(10)
    assert store.get_job(job_id)["state"] == "completed"
    row = service.handle("list_shooter_review", {"project_root": str(store.root)})[
        "candidates"
    ][0]
    assert row["shooter_evidence"]["image_source"] == "analysis_proxy"
    assert row["shooter_evidence"]["method"] == "ball_release_preview_v1"


def test_candidate_and_preview_commit_is_atomic_and_preserves_human_selection(
    release_project,
):
    service, store, video, row, source, proxy, _ = release_project
    first = render_release_previews(
        video, source, [row], store.root / "g1", "g1", proxy=proxy, offset_ms=2000
    )
    persist_evidence(store, first)
    player = store.create_player("Shooter")
    service.handle(
        "set_candidate_shooter",
        {
            "project_root": str(store.root),
            "candidate_id": row["id"],
            "generation": "g1",
            "player_id": player["id"],
            "review_state": "confirmed",
            "time_ms": first[0]["frames"][1]["time_ms"],
        },
    )
    invalid = copy.deepcopy(first)
    invalid[0]["event_time_ms"] += 1
    with pytest.raises(ProtocolError):
        store.replace_candidates(video["id"], [row], shooter_evidence=invalid)
    assert store.list_candidates()[0]["player_id"] == player["id"]
    second = render_release_previews(
        video, source, [row], store.root / "g2", "g2", proxy=proxy, offset_ms=2000
    )
    store.replace_candidates(video["id"], [row], shooter_evidence=second)
    saved = service.handle("list_shooter_review", {"project_root": str(store.root)})[
        "candidates"
    ][0]
    assert saved["player_id"] == player["id"]
    assert saved["shooter_selection"]["generation"] == "g1"
    assert saved["shooter_evidence"]["generation"] == "g2"


@pytest.mark.parametrize("failure", [None, "cancel", "error"])
def test_analysis_publishes_read_only_drafts_then_commits_cards_together(
    release_project, monkeypatch, failure
):
    service, store, video, row, source, proxy, _ = release_project
    store.save_roi(video["id"], {"x1": 0, "y1": 0, "x2": 320, "y2": 240})
    monkeypatch.setattr(service, "_ensure_detector_ready", lambda *a, **k: None)
    monkeypatch.setattr(service, "_verify_rim_crossings", lambda **kwargs: None)
    monkeypatch.setattr(service, "_prepare_candidate_previews", lambda **kwargs: {})
    observed = []

    def pipeline(commands, output, stage, **kwargs):
        def output_of(command):
            return Path(command[command.index("--output") + 1])

        new_proxy = output_of(commands[0])
        new_proxy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(proxy, new_proxy)
        coarse = {
            "candidates": [
                {
                    "time": 5,
                    "above": {"time": 4.8, "x": 60, "y": 40},
                    "below": {"time": 5.2, "x": 60, "y": 70},
                }
            ]
        }
        for command, data in [
            (commands[1], {"video": str(new_proxy), "records": []}),
            (commands[2], coarse),
        ]:
            path = output_of(command)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(data))
        stage("refine_candidates", 0.4)
        listing = service.handle(
            "list_shooter_review", {"project_root": str(store.root)}
        )
        drafts = [c for c in listing["candidates"] if c.get("draft")]
        assert len(drafts) == 1 and drafts[0]["shooter_evidence"]["frames"]
        observed.append(True)
        with pytest.raises(ProtocolError):
            service.handle(
                "set_candidate_shooter",
                {
                    "project_root": str(store.root),
                    "candidate_id": drafts[0]["id"],
                    "generation": job_id,
                    "review_state": "uncertain",
                },
            )
        if failure == "cancel":
            from engine.python.basketball_engine.adapters.analysis import (
                PipelineCancelled,
            )

            raise PipelineCancelled("JOB_CANCELLED")
        if failure == "error":
            raise RuntimeError("refine failed")
        return {
            "refined": {
                "results": [
                    {
                        "refined": [
                            {
                                "time": 5,
                                "overlay": json.loads(row["evidence_json"])["overlay"],
                            }
                        ]
                    }
                ]
            },
            "logs": [],
        }

    monkeypatch.setattr(
        "engine.python.basketball_engine.service.run_pipeline", pipeline
    )
    job_id = store.create_job(store.project()["id"], video["id"], "analysis")["id"]
    service._job_cancel_events[job_id] = threading.Event()
    service._run_analysis(
        {"project_root": str(store.root), "video_id": video["id"], "mode": "standard"},
        job_id,
    )
    assert observed
    assert (
        store.get_job(job_id)["state"]
        == {None: "completed", "cancel": "cancelled", "error": "failed"}[failure]
    )
    result = service.handle("list_shooter_review", {"project_root": str(store.root)})[
        "candidates"
    ]
    assert not any(c.get("draft") for c in result)
    if failure:
        assert [c["id"] for c in result] == [row["id"]]
    else:
        assert result[0]["shooter_evidence"]["method"] == "ball_release_preview_v1"
        latest = service.handle(
            "list_shooter_review", {"project_root": str(store.root)}
        )["jobs"][0]
        assert latest["id"] == job_id and latest["state"] == "completed"


@pytest.fixture
def prepared_label(release_project):
    service, store, video, row, source, proxy, _ = release_project
    evidence = render_release_previews(
        video, source, [row], store.root / "saved", "g1", proxy=proxy, offset_ms=2000
    )
    persist_evidence(store, evidence)
    player = store.create_player("Shooter")
    return service, store, {
        "project_root": str(store.root),
        "candidate_id": row["id"],
        "generation": "g1",
        "player_id": player["id"],
        "review_state": "confirmed",
        "time_ms": evidence[0]["frames"][1]["time_ms"],
    }


def test_label_reopens_without_changing_basket_review(prepared_label):
    service, store, payload = prepared_label
    with store.connect() as connection:
        connection.execute(
            """INSERT OR REPLACE INTO candidate_reviews
            (candidate_id,status,reason,note,review_duration_ms,updated_at)
            VALUES (?,'excluded','missed','keep note',123,'2026-01-01T00:00:00Z')""",
            (payload["candidate_id"],),
        )
    service.handle("set_candidate_shooter", payload)
    reopened = EngineService()
    try:
        row = reopened.handle("list_shooter_review", {"project_root": str(store.root)})[
            "candidates"
        ][0]
        assert row["player_id"] == payload["player_id"]
        assert row["shooter_selection"]["time_ms"] == payload["time_ms"]
        with store.connect() as connection:
            saved = connection.execute(
                "SELECT status,reason,note,review_duration_ms FROM candidate_reviews WHERE candidate_id=?",
                (payload["candidate_id"],),
            ).fetchone()
        assert tuple(saved) == ("excluded", "missed", "keep note", 123)
    finally:
        reopened.shutdown()


@pytest.mark.parametrize(
    "field,value",
    [("generation", "old"), ("time_ms", 999999), ("player_id", "foreign"), ("track_id", 1)],
)
def test_invalid_selection_cannot_replace_a_saved_label(prepared_label, field, value):
    service, store, payload = prepared_label
    service.handle("set_candidate_shooter", payload)
    with pytest.raises(ProtocolError):
        service.handle("set_candidate_shooter", {**payload, field: value})
    assert store.list_candidates()[0]["player_id"] == payload["player_id"]


def test_source_change_hides_old_stills_and_rejects_labels(prepared_label, release_project):
    service, store, payload = prepared_label
    release_project[4].write_bytes(b"changed source")
    row = service.handle("list_shooter_review", {"project_root": str(store.root)})[
        "candidates"
    ][0]
    assert row["shooter_evidence"] is None and row["shooter_evidence_stale"]
    with pytest.raises(ProtocolError):
        service.handle("set_candidate_shooter", payload)


@pytest.mark.parametrize("cancelled", [False, True])
def test_refresh_failure_preserves_evidence_and_labels(prepared_label, monkeypatch, cancelled):
    from engine.python.basketball_engine.adapters.analysis import PipelineCancelled

    service, store, payload = prepared_label
    service.handle("set_candidate_shooter", payload)

    def fail(*args, **kwargs):
        raise PipelineCancelled("JOB_CANCELLED") if cancelled else RuntimeError("read failed")

    monkeypatch.setattr("engine.python.basketball_engine.shooter_review.render_release_previews", fail)
    job_id = service.handle("prepare_shooter_review", {"project_root": str(store.root)})[
        "job"
    ]["id"]
    for thread in list(service._job_threads.values()):
        thread.join(10)
    assert store.get_job(job_id)["state"] == ("cancelled" if cancelled else "failed")
    row = service.handle("list_shooter_review", {"project_root": str(store.root)})[
        "candidates"
    ][0]
    assert row["shooter_evidence"]["generation"] == "g1"
    assert row["player_id"] == payload["player_id"]
    store.create_job(store.project()["id"], row["video_id"], "analysis")
    with pytest.raises(ProtocolError, match="现有"):
        service.handle("prepare_shooter_review", {"project_root": str(store.root)})
