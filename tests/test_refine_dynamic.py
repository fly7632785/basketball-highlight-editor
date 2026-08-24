import json
import os
import subprocess
import sys
import unittest
from argparse import Namespace
from pathlib import Path

import pytest

import refine_dynamic_candidates
from refine_dynamic_candidates import build_scan_windows, file_fingerprint, scale_rim
import scan_video
from export_review_queue import concat_manifest_entry


class RefineDynamicTest(unittest.TestCase):
    def test_build_scan_windows_merges_overlapping_candidates(self):
        result = build_scan_windows([10.0, 12.0, 30.0], window=2.5)
        self.assertEqual([item["indices"] for item in result], [[0, 1], [2]])
        self.assertAlmostEqual(result[0]["start"], 7.5)
        self.assertAlmostEqual(result[0]["end"], 14.5)


def test_main_does_not_load_yolo_when_all_detection_caches_hit(tmp_path, monkeypatch):
    video = tmp_path / "source.mp4"
    model_path = tmp_path / "model.pt"
    coarse_path = tmp_path / "coarse.json"
    cache_dir = tmp_path / "cache"
    output = tmp_path / "refined.json"
    video.write_bytes(b"video")
    model_path.write_bytes(b"model")
    rim = {"center_x": 100, "rim_y": 80, "width": 40, "height": 20}
    coarse_path.write_text(json.dumps({"candidates": [{"time": 5.0, "rim": rim}]}), encoding="utf-8")

    scaled_rim = scale_rim(rim, 2.0)
    cache_key = json.dumps({
        "algorithm_version": refine_dynamic_candidates.DETECTION_CACHE_VERSION,
        "schema_version": refine_dynamic_candidates.REFINED_SCHEMA_VERSION,
        "video": file_fingerprint(video),
        "model": file_fingerprint(model_path),
        "roi": [0, 0, 200, 200],
        "time": 5.0,
        "window": 2.5,
        "sample_fps": 30,
        "scale": 2,
        "conf": 0.1,
        "batch": 8,
        "rim": scaled_rim,
        "net_roi": None,
        "signal_version": 4,
    }, sort_keys=True).encode()
    cache_dir.mkdir()
    (cache_dir / (refine_dynamic_candidates.hashlib.sha256(cache_key).hexdigest()[:24] + ".json")).write_text(
        "[]", encoding="utf-8"
    )

    def fail_if_loaded(_model_path):
        pytest.fail("YOLO must not be initialized when all detection caches hit")

    monkeypatch.setattr(refine_dynamic_candidates, "load_yolo_model", fail_if_loaded)
    monkeypatch.setattr(
        refine_dynamic_candidates,
        "select_device",
        lambda _requested: pytest.fail("device detection must be deferred on cache hit"),
    )
    refine_dynamic_candidates.main(Namespace(
        video=str(video),
        model=str(model_path),
        coarse=str(coarse_path),
        roi=[0, 0, 200, 200],
        net_roi=None,
        proxy_scale=2.0,
        window=2.5,
        sample_fps=30,
        scale=2,
        conf=0.1,
        batch=8,
        cache_dir=cache_dir,
        min_score=0.0,
        device="auto",
        output=str(output),
    ))

    result = json.loads(output.read_text(encoding="utf-8"))
    assert result["cache_hits"] == 1
    assert result["scan_groups"] == 0
    assert result["device"] == "auto"


def test_refine_dynamic_module_defers_heavy_detection_imports():
    script = """
import builtins

blocked = {"cv2", "torch", "ultralytics"}
original_import = builtins.__import__

def guarded_import(name, *args, **kwargs):
    if name.split('.', 1)[0] in blocked:
        raise AssertionError(f"heavy detection dependency imported: {name}")
    return original_import(name, *args, **kwargs)

builtins.__import__ = guarded_import
import refine_dynamic_candidates
"""
    env = os.environ.copy()
    env["PYTHONPATH"] = os.pathsep.join(
        str(path) for path in (
            Path(__file__).parents[1] / "src",
            Path(__file__).parents[1] / "scripts",
        )
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


def test_scan_video_rejects_invalid_parameters_before_loading_dependencies(tmp_path, monkeypatch):
    video = tmp_path / "source.mp4"
    model_path = tmp_path / "model.pt"
    video.write_bytes(b"video")
    model_path.write_bytes(b"model")
    args = Namespace(
        video=str(video),
        model=str(model_path),
        output=str(tmp_path / "detections.json"),
        roi=[0, 0, 200, 200],
        sample_fps=5,
        duration=None,
        time_offset=0.0,
        scale=0,
        batch=8,
        conf=0.15,
        device="auto",
        cache_dir=None,
    )
    monkeypatch.setattr(scan_video, "load_yolo_model", lambda _: pytest.fail("model should not load"))

    with pytest.raises(ValueError, match="SCAN_PARAMETERS_INVALID"):
        scan_video.scan_video(args)


def test_concat_manifest_escapes_single_quotes(tmp_path):
    path = tmp_path / "coach's clip.mp4"
    assert concat_manifest_entry(path) == f"file '{path.as_posix().replace(chr(39), chr(39) + chr(92) + chr(39) + chr(39))}'\n"


def test_scan_video_cache_hit_skips_video_and_model_loading(tmp_path, monkeypatch):
    video = tmp_path / "source.mp4"
    model_path = tmp_path / "model.pt"
    cache_dir = tmp_path / "cache"
    output = tmp_path / "detections.json"
    video.write_bytes(b"video")
    model_path.write_bytes(b"model")
    args = Namespace(
        video=str(video),
        model=str(model_path),
        output=str(output),
        roi=[0, 0, 200, 200],
        sample_fps=5,
        duration=None,
        time_offset=0.0,
        scale=4,
        batch=8,
        conf=0.15,
        device="cpu",
        cache_dir=cache_dir,
    )
    cache_key = scan_video.hashlib.sha256(json.dumps({
        "video": str(video.resolve()),
        "video_size": video.stat().st_size,
        "video_mtime_ns": video.stat().st_mtime_ns,
        "model": str(model_path.resolve()),
        "model_size": model_path.stat().st_size,
        "model_mtime_ns": model_path.stat().st_mtime_ns,
        "roi": args.roi,
        "sample_fps": args.sample_fps,
        "duration": args.duration,
        "time_offset": args.time_offset,
        "scale": args.scale,
        "batch": args.batch,
        "conf": args.conf,
    }, sort_keys=True).encode()).hexdigest()
    cache_dir.mkdir()
    cached = {"records": [], "device": "cpu"}
    (cache_dir / f"{cache_key[:24]}.json").write_text(json.dumps(cached), encoding="utf-8")

    def fail_if_loaded(_model_path):
        pytest.fail("YOLO must not be initialized when coarse detection cache hits")

    monkeypatch.setattr(scan_video, "load_yolo_model", fail_if_loaded)
    monkeypatch.setattr(scan_video, "open_video", fail_if_loaded)
    monkeypatch.setattr(
        scan_video,
        "select_device",
        lambda _requested: pytest.fail("device detection must be deferred on cache hit"),
    )
    args.device = "auto"
    scan_video.scan_video(args)

    assert json.loads(output.read_text(encoding="utf-8")) == cached


def test_scan_video_module_defers_heavy_detection_imports():
    script = """
import builtins

blocked = {"cv2", "torch", "ultralytics"}
original_import = builtins.__import__

def guarded_import(name, *args, **kwargs):
    if name.split('.', 1)[0] in blocked:
        raise AssertionError(f"heavy detection dependency imported: {name}")
    return original_import(name, *args, **kwargs)

builtins.__import__ = guarded_import
import scan_video
"""
    env = os.environ.copy()
    env["PYTHONPATH"] = os.pathsep.join(
        str(path) for path in (
            Path(__file__).parents[1] / "src",
            Path(__file__).parents[1] / "scripts",
        )
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


if __name__ == "__main__":
    unittest.main()
