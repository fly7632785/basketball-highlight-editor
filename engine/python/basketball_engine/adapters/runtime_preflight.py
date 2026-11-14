"""Session-scoped detector checks, isolated from the JSONL engine process."""

import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import threading
import time

from .analysis import PipelineCancelled, terminate_process
from ..diagnostics import log_diagnostic
from ..protocol import ProtocolError

RESULT_PREFIX = "BHE_PREFLIGHT_RESULT="
WINDOWS_MESSAGE = "分析引擎在这台电脑上无法启动（运行库初始化失败）。请先安装最新的 VC++ 运行库后重启电脑，仍然不行请把 CPU 型号和诊断信息发给我们。"
GENERIC_MESSAGE = "分析引擎在这台电脑上无法启动（运行库初始化失败）。请检查或重新安装应用，仍然不行请把系统版本、CPU 型号和诊断信息发给我们。"
DEPENDENCY_MESSAGE = "分析引擎缺少模型加载依赖，请安装最新版本的应用，仍然不行请发送诊断信息。"


def runtime_error(details, missing_module=None):
    message = DEPENDENCY_MESSAGE if missing_module else (
        WINDOWS_MESSAGE if platform.system() == "Windows" else GENERIC_MESSAGE
    )
    return ProtocolError("ENGINE_RUNTIME_UNAVAILABLE", f"{message}\n{details}")


def check_detector(repo_root, model_path, device, cancel_check=None, process_callback=None, timeout=300):
    command = [sys.executable, str(repo_root / "scripts" / "check_detector.py"),
               "--model", str(model_path), "--device", device]
    options = {
        "stdin": subprocess.DEVNULL, "stdout": subprocess.PIPE, "stderr": subprocess.PIPE,
        "text": True, "encoding": "utf-8", "errors": "replace",
    }
    if os.name == "nt":
        options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
    else:
        options["start_new_session"] = True
    if cancel_check and cancel_check():
        raise PipelineCancelled("JOB_CANCELLED")
    started = time.monotonic()
    try:
        process = subprocess.Popen(command, **options)
    except OSError as exc:
        log_diagnostic(f"detector preflight warning: could not start check; continuing analysis: {exc}")
        return None
    if process_callback:
        process_callback(process)
    try:
        while True:
            if cancel_check and cancel_check():
                terminate_process(process)
                process.communicate()
                raise PipelineCancelled("JOB_CANCELLED")
            if time.monotonic() - started >= timeout:
                terminate_process(process)
                stdout, stderr = process.communicate()
                log_diagnostic(f"detector preflight warning: timed out after {timeout}s; continuing analysis\n{stdout}\n{stderr}")
                return None
            try:
                stdout, stderr = process.communicate(timeout=0.1)
                break
            except subprocess.TimeoutExpired:
                continue
    except (OSError, subprocess.SubprocessError) as exc:
        try:
            terminate_process(process)
        except (OSError, subprocess.SubprocessError):
            pass
        log_diagnostic(f"detector preflight warning: check could not complete; continuing analysis: {exc}")
        return None
    finally:
        if process_callback:
            process_callback(None)
    if cancel_check and cancel_check():
        raise PipelineCancelled("JOB_CANCELLED")
    for line in reversed(stdout.splitlines()):
        if not line.startswith(RESULT_PREFIX):
            continue
        try:
            result = json.loads(line[len(RESULT_PREFIX):])
        except (ValueError, TypeError):
            break
        if not isinstance(result, dict):
            break
        if (process.returncode == 0 and result.get("status") == "ready"
                and result.get("device") in {"cpu", "cuda", "mps", "dml", "coreml"}
                and isinstance(result.get("load_ms"), (int, float))):
            result["elapsed_ms"] = round((time.monotonic() - started) * 1000)
            log_diagnostic(f"detector preflight ready requested={device} device={result['device']} load_ms={result['load_ms']} elapsed_ms={result['elapsed_ms']}")
            return result
        if (process.returncode != 0 and result.get("status") == "unavailable"
                and result.get("error_code") == "ENGINE_RUNTIME_UNAVAILABLE"
                and isinstance(result.get("details"), str)):
            raise runtime_error(f"exit={process.returncode}\n{stderr.strip() or result['details']}",
                                missing_module=result.get("missing_module"))
        break
    details = f"exit={process.returncode}\n{stderr}\n{stdout}".strip()
    log_diagnostic(f"detector preflight warning: inconclusive check; continuing analysis\n{details}")
    return None


class DetectorPreflight:
    def __init__(self):
        self._ready = {}
        self._lock = threading.Lock()

    def ensure(self, repo_root, model_path, device, cancel_check=None, process_callback=None):
        # Use the safe backend in both the child command and cache key. An old
        # auto -> MPS result must not be reused on Intel macOS.
        if device == "auto" and platform.system() == "Darwin" and platform.machine() == "x86_64":
            device = "cpu"
        model_path = Path(model_path).resolve()
        info = model_path.stat()
        key = (device, str(model_path), info.st_size, info.st_mtime_ns)
        while not self._lock.acquire(timeout=0.1):
            if cancel_check and cancel_check():
                raise PipelineCancelled("JOB_CANCELLED")
        try:
            if cancel_check and cancel_check():
                raise PipelineCancelled("JOB_CANCELLED")
            if key in self._ready and not (device == "cpu" and self._ready[key]["device"] != "cpu"):
                log_diagnostic(f"detector preflight cache hit requested={device} device={self._ready[key]['device']}")
                return {**self._ready[key], "cached": True}
            result = check_detector(repo_root, model_path, device, cancel_check, process_callback)
            if result is not None:
                self._ready[key] = result
            return result
        finally:
            self._lock.release()

    def invalidate(self):
        with self._lock:
            self._ready.clear()
