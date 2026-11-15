import builtins
from contextlib import nullcontext
from types import SimpleNamespace
import sys

import pytest

from engine.python.basketball_engine import diagnostics as diag
from engine.python.basketball_engine.service import ANALYSIS_ALGORITHM_VERSION


@pytest.fixture
def registry(monkeypatch):
    def query(key, name):
        if name == 'ProcessorNameString':
            return ('  Example CPU\nModel  ', 1)
        return (['GPU 0', 'GPU 0', 'GPU 1', 'GPU 2', 'GPU 3'][int(key)], 1)

    fake = SimpleNamespace(HKEY_LOCAL_MACHINE='hklm',
                           OpenKey=lambda key, name: nullcontext(name), QueryValueEx=query,
                           QueryInfoKey=lambda key: (5, 0, 0), EnumKey=lambda key, index: str(index))
    monkeypatch.setitem(sys.modules, 'winreg', fake)
    return fake


def test_windows_cpu_and_gpu_registry_reading(registry, monkeypatch):
    monkeypatch.setattr(diag.platform, 'system', lambda: 'Windows')
    assert diag._cpu_name() == 'Example CPU\nModel'
    assert diag._windows_gpu_names() == ['GPU 0', 'GPU 1', 'GPU 2']


def test_cpu_sysctl_has_a_five_second_timeout(monkeypatch):
    monkeypatch.setattr(diag.platform, 'system', lambda: 'Darwin')

    def run(command, **kwargs):
        assert command == ['sysctl', '-n', 'machdep.cpu.brand_string']
        assert kwargs['timeout'] == 5
        return SimpleNamespace(stdout='Apple test CPU\n')

    monkeypatch.setattr(diag.subprocess, 'run', run)
    assert diag._cpu_name() == 'Apple test CPU'


def test_linux_model_name(monkeypatch):
    monkeypatch.setattr(diag.platform, 'system', lambda: 'Linux')
    monkeypatch.setattr(diag.Path, 'read_text', lambda *args, **kwargs: 'processor: 0\nmodel name : Example Linux CPU\n')
    assert diag._cpu_name() == 'Example Linux CPU'


def test_versions_use_metadata_without_importing_native_libraries(monkeypatch):
    original = builtins.__import__

    def guarded(name, *args, **kwargs):
        assert name not in {'torch', 'onnxruntime', 'ultralytics', 'numpy', 'cv2'}
        return original(name, *args, **kwargs)

    def version(name):
        if name not in {'torch', 'opencv-python-headless'}:
            raise diag.metadata.PackageNotFoundError(name)
        return 'test-version'

    monkeypatch.setattr(builtins, '__import__', guarded)
    monkeypatch.setattr(diag.metadata, 'version', version)
    assert diag._library_versions() == {'torch': 'test-version', 'opencv-python-headless': 'test-version'}


@pytest.mark.parametrize('failed', ['_cpu_name', '_library_versions', '_windows_gpu_names',
                                   '_windows_environment', '_total_memory_bytes', '_ffmpeg_version'])
def test_probe_failures_are_independent(failed, monkeypatch):
    monkeypatch.setattr(diag.platform, 'system', lambda: 'Windows')
    monkeypatch.setattr(diag, '_cpu_name', lambda: 'CPU')
    monkeypatch.setattr(diag, '_library_versions', lambda: {'numpy': 'test'})
    monkeypatch.setattr(diag, '_windows_gpu_names', lambda: ['GPU'])
    monkeypatch.setattr(diag, '_windows_environment', lambda: ' avx=true avx2=true avx512f=false msvcp140=14.0.0.0')
    monkeypatch.setattr(diag, '_ffmpeg_version', lambda _: 'test')

    def fail(*args):
        raise RuntimeError('unreadable probe')

    monkeypatch.setattr(diag, failed, fail)
    value = diag.environment_summary()
    assert value.startswith(f'environment engine={diag.__version__} ')
    assert value.endswith('algorithm=' + ANALYSIS_ALGORITHM_VERSION)
    if failed != '_cpu_name':
        assert 'cpu_name="CPU"' in value
    if failed != '_library_versions':
        assert 'libs={"numpy":"test"}' in value
    if failed != '_windows_gpu_names':
        assert 'gpu=["GPU"]' in value


def test_cpu_timeout_is_unknown_without_losing_library_versions(monkeypatch):
    monkeypatch.setattr(diag.platform, 'system', lambda: 'Darwin')

    def timeout(*args, **kwargs):
        raise diag.subprocess.TimeoutExpired('sysctl', 5)

    monkeypatch.setattr(diag.subprocess, 'run', timeout)
    monkeypatch.setattr(diag, '_library_versions', lambda: {'numpy': 'test'})
    value = diag.environment_summary()
    assert 'cpu_name="unknown"' in value
    assert 'libs={"numpy":"test"}' in value
    assert ' gpu=' not in value


def test_environment_keeps_windows_fields_and_escapes_newlines(registry, monkeypatch):
    monkeypatch.setattr(diag.platform, 'system', lambda: 'Windows')
    monkeypatch.setattr(diag, '_windows_environment', lambda: ' avx=true avx2=false avx512f=false msvcp140=unknown')
    monkeypatch.setattr(diag, '_ffmpeg_version', lambda _: 'test')
    monkeypatch.setattr(diag, '_library_versions', lambda: {})
    value = diag.environment_summary()
    assert ' avx=true avx2=false avx512f=false msvcp140=unknown cpu_name=' in value
    assert '\n' not in value
    assert r'Example CPU\nModel' in value
    assert 'libs={}' in value
