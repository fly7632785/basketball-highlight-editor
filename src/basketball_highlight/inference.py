"""推理后端解析：决定用哪条推理路径，并把"模型对象"统一成一个工厂。

调用方只关心两件事：
1. ``select_device()`` 返回 ``cpu | cuda | mps | dml``；
2. ``load_detector()`` 返回一个拥有 ``predict()`` 的对象。

优先级（``auto``）：cuda > dml > mps > cpu。CUDA 比 DML 快（1.95 vs 2.88 ms/张），
所以装了 CUDA 版 torch 的机器应该走 CUDA；DML 只负责"有显卡但 torch 是 CPU 版"这个
Windows 上最常见的情况。
"""
from __future__ import annotations

import sys
from functools import lru_cache
from pathlib import Path
from typing import Any

SUPPORTED_DEVICES = ("auto", "cpu", "cuda", "mps", "dml")

# 进程内选定的后端。脚本先 select_device() 再 load_detector(),
# 后者可能因为 onnx 缺失或建会话失败而回落,届时这里会被改写成实际后端。
_STATE: dict[str, str] = {"device": "cpu"}


def current_device() -> str:
    """当前进程实际使用的推理后端。"""
    return _STATE["device"]


def _remember(device: str) -> str:
    _STATE["device"] = device
    return device


def onnx_path_for(model_path: str | Path) -> Path:
    """由 ``.pt`` 推出同名的 ``.onnx``（导出脚本写在那里）。"""
    path = Path(model_path)
    if path.suffix.lower() == ".onnx":
        return path
    return path.with_suffix(".onnx")


@lru_cache(maxsize=1)
def _torch_cuda_available() -> bool:
    try:
        import torch
    except ImportError:
        return False
    try:
        return bool(torch.cuda.is_available())
    except (RuntimeError, OSError):
        return False


@lru_cache(maxsize=1)
def _torch_mps_available() -> bool:
    try:
        import torch
    except ImportError:
        return False
    try:
        return bool(torch.backends.mps.is_available())
    except (AttributeError, RuntimeError, OSError):
        return False


@lru_cache(maxsize=1)
def _dml_provider_available() -> bool:
    """只探测 provider 是否注册，不建会话（建会话要几百毫秒）。"""
    try:
        import onnxruntime as ort
    except ImportError:
        return False
    try:
        return "DmlExecutionProvider" in ort.get_available_providers()
    except Exception:
        return False


def dml_available(model_path: str | Path | None = None) -> bool:
    if not _dml_provider_available():
        return False
    if model_path is None:
        return True
    return onnx_path_for(model_path).is_file()


def resolve_device(requested: str = "auto", model_path: str | Path | None = None) -> str:
    """把 ``auto`` 解析成具体设备；显式请求不可用时降级到 cpu。

    降级而不是抛错：分析任务的可用性优先于加速，缺省路径必须始终能跑。
    """
    requested = (requested or "auto").strip().lower()
    if requested not in SUPPORTED_DEVICES:
        raise ValueError(f"unsupported device: {requested}")
    if requested != "auto":
        return requested

    if _torch_cuda_available():
        return "cuda"
    if dml_available(model_path):
        return "dml"
    if _torch_mps_available():
        return "mps"
    return "cpu"


def select_device(requested: str = "auto", model_path: str | Path | None = None) -> str:
    """脚本层入口：解析后如果目标后端根本不可用，退到 cpu。

    结果会记进进程状态，``load_detector()`` 不传 device 时沿用它。
    """
    device = resolve_device(requested, model_path)
    if device == "dml" and not dml_available(model_path):
        device = "cpu"
    if device == "cuda" and not _torch_cuda_available():
        device = "cpu"
    if device == "mps" and not _torch_mps_available():
        device = "cpu"
    return _remember(device)


def max_batch_for(device: str) -> int:
    """各后端的推荐批大小；DML 的 dynamic shape 小批量会退化，只能单张。"""
    return {"dml": 1, "cpu": 8, "cuda": 16, "mps": 8}.get(device, 8)


def load_detector(
    model_path: str | Path,
    device: str | None = None,
    **kwargs: Any,
) -> Any:
    """按设备返回检测器：``dml`` 走 ORT，其余走 ultralytics/torch。

    ``device=None`` 时沿用 ``select_device()`` 选定的后端。DirectML 需要的
    ``.onnx`` 缺失、或 ORT 建会话失败时，自动退回 torch，并把实际后端写回状态。
    """
    path = Path(model_path)
    target = (device or _STATE["device"] or "cpu").lower()

    if target == "dml":
        from .onnx_detector import OnnxDetector

        onnx_path = onnx_path_for(path)
        if onnx_path.is_file():
            detector = OnnxDetector(onnx_path, device="dml", **kwargs)
            _remember(detector.device)
            return detector
        print(
            f"device=dml skipped: {onnx_path.name} not found "
            f"(run scripts/export_mobile_model.py --dynamic); falling back to cpu",
            file=sys.stderr,
        )
        target = "cpu"

    from ultralytics import YOLO

    _remember(target if target in {"cuda", "mps"} else "cpu")
    return YOLO(str(path))


def backend_report(model_path: str | Path | None = None) -> dict[str, Any]:
    """给诊断日志/check_runtime 用的后端可用性快照。"""
    report: dict[str, Any] = {
        "torch_cuda": _torch_cuda_available(),
        "torch_mps": _torch_mps_available(),
        "ort_dml": _dml_provider_available(),
        "onnx_model": None,
    }
    try:
        import onnxruntime as ort

        report["onnxruntime"] = ort.__version__
    except ImportError:
        report["onnxruntime"] = None
    if model_path is not None:
        onnx_path = onnx_path_for(model_path)
        report["onnx_model"] = str(onnx_path) if onnx_path.is_file() else None
    return report
