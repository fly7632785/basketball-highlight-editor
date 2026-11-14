"""Intel device policy, stale preflight results, and real MPS CPU fallback."""
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from basketball_highlight import inference
from engine.python.basketball_engine.adapters import runtime_preflight


def test_intel_macos_auto_uses_cpu_without_probing_gpu(monkeypatch):
    monkeypatch.setattr(inference.sys, "platform", "darwin")
    monkeypatch.setattr(inference.platform, "machine", lambda: "x86_64")

    def unexpected():
        raise AssertionError("Intel auto must not probe an accelerated backend")

    monkeypatch.setattr(inference, "_cuda_possible", unexpected)
    monkeypatch.setattr(inference, "dml_available", lambda _: unexpected())
    monkeypatch.setattr(inference, "coreml_available", lambda _: unexpected())
    monkeypatch.setattr(inference, "_torch_mps_available", unexpected)
    assert inference.select_device("auto") == "cpu"
    assert inference.current_device() == "cpu"


@pytest.mark.parametrize("system,machine,expected", [
    ("darwin", "arm64", "mps"),
    ("linux", "x86_64", "cuda"),
    ("win32", "x86_64", "cuda"),
])
def test_other_platform_auto_policy_is_unchanged(monkeypatch, system, machine, expected):
    monkeypatch.setattr(inference.sys, "platform", system)
    monkeypatch.setattr(inference.platform, "machine", lambda: machine)
    monkeypatch.setattr(inference, "_cuda_possible", lambda: system != "darwin")
    monkeypatch.setattr(inference, "_torch_cuda_available", lambda: True)
    monkeypatch.setattr(inference, "dml_available", lambda _: False)
    monkeypatch.setattr(inference, "coreml_available", lambda _: False)
    monkeypatch.setattr(inference, "_torch_mps_available", lambda: True)
    assert inference.select_device("auto") == expected


@pytest.mark.parametrize("machine,expected", [("x86_64", "cpu"), ("arm64", "mps")])
def test_coreml_missing_model_keeps_platform_fallback(tmp_path, monkeypatch, machine, expected):
    monkeypatch.setattr(inference.sys, "platform", "darwin")
    monkeypatch.setattr(inference.platform, "machine", lambda: machine)
    fake = type(sys)("ultralytics")
    detector = object()
    fake.YOLO = lambda _: detector
    monkeypatch.setitem(sys.modules, "ultralytics", fake)
    assert inference.load_detector(tmp_path / "model.pt", device="coreml") is detector
    assert inference.current_device() == expected


def test_intel_preflight_ignores_old_auto_mps_and_bad_cpu_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(runtime_preflight.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(runtime_preflight.platform, "machine", lambda: "x86_64")
    model = tmp_path / "model.pt"
    model.write_bytes(b"model")
    stat = model.stat()
    suffix = (str(model.resolve()), stat.st_size, stat.st_mtime_ns)
    preflight = runtime_preflight.DetectorPreflight()
    old = {"status": "ready", "device": "mps", "load_ms": 1}
    preflight._ready[("auto", *suffix)] = old
    preflight._ready[("cpu", *suffix)] = old
    calls = []

    def check(repo, path, device, *_):
        calls.append(device)
        return {"status": "ready", "device": device, "load_ms": 1}

    monkeypatch.setattr(runtime_preflight, "check_detector", check)
    assert preflight.ensure(tmp_path, model, "auto")["device"] == "cpu"
    assert preflight.ensure(tmp_path, model, "auto")["cached"] is True
    assert calls == ["cpu"]
    assert runtime_preflight.DetectorPreflight()._ready == {}


def test_apple_silicon_keeps_a_valid_mps_preflight_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(runtime_preflight.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(runtime_preflight.platform, "machine", lambda: "arm64")
    model = tmp_path / "model.pt"
    model.write_bytes(b"model")
    stat = model.stat()
    preflight = runtime_preflight.DetectorPreflight()
    preflight._ready[("auto", str(model.resolve()), stat.st_size, stat.st_mtime_ns)] = {
        "status": "ready", "device": "mps", "load_ms": 1,
    }
    result = preflight.ensure(tmp_path, model, "auto")
    assert result["cached"] is True
    assert result["device"] == "mps"


@pytest.mark.parametrize("override", [None, "0", "1"])
def test_package_bootstrap_sets_fallback_before_torch_and_respects_override(override):
    env = os.environ.copy()
    env.pop("PYTORCH_ENABLE_MPS_FALLBACK", None)
    if override is not None:
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = override
    source = str(Path(__file__).resolve().parents[1] / "src")
    code = f"""
import sys, os
sys.path.insert(0, {source!r})
import basketball_highlight
assert 'torch' not in sys.modules
assert os.environ['PYTORCH_ENABLE_MPS_FALLBACK'] == {(override or '1')!r}
"""
    subprocess.run([sys.executable, "-c", code], env=env, check=True, capture_output=True, timeout=30)


def test_real_missing_mps_operator_falls_back_only_with_early_bootstrap():
    source = str(Path(__file__).resolve().parents[1] / "src")
    code = f"""
import json, os, sys, importlib.util
sys.path.insert(0, {source!r})
if importlib.util.find_spec('torch') is None:
    print(json.dumps({{'skip': 'torch is not installed'}})); sys.exit(0)
if sys.argv[1] == 'bootstrap':
    import basketball_highlight
import torch
if not torch.backends.mps.is_available():
    print(json.dumps({{'skip': 'MPS hardware is unavailable'}})); sys.exit(0)
if sys.argv[1] == 'late':
    os.environ['PYTORCH_ENABLE_MPS_FALLBACK'] = '1'
x = torch.tensor([[2., 1.], [1., 2.]], device='mps')
try:
    result = torch.geqrf(x)
except NotImplementedError as error:
    print(json.dumps({{'missing': str(error)}}))
else:
    expected = torch.geqrf(x.cpu())
    for actual, reference in zip(result, expected):
        torch.testing.assert_close(actual.cpu(), reference)
    print(json.dumps({{'ok': True}}))
"""
    results = {}
    for mode in ["none", "late", "bootstrap"]:
        env = os.environ.copy()
        env.pop("PYTORCH_ENABLE_MPS_FALLBACK", None)
        child = subprocess.run([sys.executable, "-c", code, mode], env=env,
                               capture_output=True, text=True, check=True, timeout=120)
        result = json.loads(child.stdout.strip().splitlines()[-1])
        if "skip" in result:
            pytest.skip(result["skip"])
        results[mode] = result
    if "missing" not in results["none"]:
        pytest.skip("This torch version has a native MPS geqrf kernel")
    assert "geqrf" in results["none"]["missing"]
    assert "geqrf" in results["late"]["missing"]
    assert results["bootstrap"] == {"ok": True}
