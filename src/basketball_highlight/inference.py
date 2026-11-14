"""推理后端解析：决定用哪条推理路径，并把"模型对象"统一成一个工厂。

调用方只关心两件事：
1. ``select_device()`` 返回 ``cpu | cuda | mps | dml | coreml``；
2. ``load_detector()`` 返回一个拥有 ``predict()`` 的对象。

Intel macOS 的 ``auto`` 固定使用 CPU，避免缺失的 MPS 算子中断分析。
其他平台优先级（``auto``）：cuda > dml > coreml > mps > cpu。CUDA 比 DML 快（1.95 vs 2.88 ms/张），
所以装了 CUDA 版 torch 的机器应该走 CUDA；DML 只负责"有显卡但 torch 是 CPU 版"这个
Windows 上最常见的情况。``coreml`` 排在 mps 前面：Apple Silicon 上端到端比 mps 快约 30%
（粗扫/精筛/复核三段合计 99.2s → 69.2s），基准见
``docs/benchmarks/COREML_BACKEND_BENCHMARK_20261025.md``。
"""
from __future__ import annotations

import platform
import sys
from functools import lru_cache
from pathlib import Path
from typing import Any

from .runtime_errors import DetectorRuntimeUnavailable, is_runtime_failure

SUPPORTED_DEVICES = ("auto", "cpu", "cuda", "mps", "dml", "coreml")

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


def static_onnx_path_for(model_path: str | Path) -> Path:
    """macOS CoreML 用的静态 batch=1 模型（与 Windows 动态模型分开）。

    CoreML 上动态 batch 只有 35 ms/帧，静态 640² 是 9.1 ms，所以两条产物必须并存：
    Windows 继续用 ``bball_model.onnx``，macOS 只认 ``bball_model.static.onnx``。
    分开命名还能保证误把动态模型塞给 CoreML 时 ``coreml_available()`` 直接返回 False。
    """
    path = Path(model_path)
    if path.suffix.lower() == ".onnx":
        return path
    return path.with_name(path.stem + ".static.onnx")


@lru_cache(maxsize=1)
def _cuda_possible() -> bool:
    """这台机器有没有可能跑 CUDA。

    macOS 从 CUDA 10.2 起就没有支持，torch 也不带 CUDA 后端；先判平台能省掉一次
    ``import torch``（3 s 级），否则 auto 在 Apple Silicon 上为了确认"没有 cuda"
    就会先付掉这次启动成本，把 CoreML 省下的时间又还回去。
    """
    return sys.platform != "darwin"


@lru_cache(maxsize=1)
def _torch_cuda_available() -> bool:
    try:
        import torch
    except (ImportError, OSError):
        # Windows 上 c10.dll 初始化失败(WinError 1114)抛的是 OSError。
        return False
    try:
        return bool(torch.cuda.is_available())
    except (RuntimeError, OSError):
        return False


@lru_cache(maxsize=1)
def _torch_mps_available() -> bool:
    try:
        import torch
    except (ImportError, OSError):
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


@lru_cache(maxsize=1)
def _coreml_provider_available() -> bool:
    """只探测 provider 是否注册，不建会话（CoreML 建会话要 0.23–0.6 s）。"""
    try:
        import onnxruntime as ort
    except ImportError:
        return False
    try:
        return "CoreMLExecutionProvider" in ort.get_available_providers()
    except Exception:
        return False


@lru_cache(maxsize=1)
def _coreml_experiment_scope() -> bool:
    """CoreML 只在本轮实测过的范围内放行：Apple Silicon。

    基准数据全部来自 arm64（M2）。Intel Mac 上 CoreML 走另一条 Metal 路径，
    wheel 里同样有 ``CoreMLExecutionProvider``，但没有任何实测数字，先不让它生效，
    免得老机型在不知情的情况下变慢。非 macOS 平台本来就拿不到该 provider，
    这里返回 True 只是不额外拦截。
    """
    if sys.platform != "darwin":
        return True
    return platform.machine() == "arm64"


def coreml_available(model_path: str | Path | None = None) -> bool:
    if not _coreml_experiment_scope():
        return False
    if not _coreml_provider_available():
        return False
    if model_path is None:
        return True
    return static_onnx_path_for(model_path).is_file()


def _intel_macos() -> bool:
    return sys.platform == "darwin" and platform.machine() == "x86_64"


def resolve_device(requested: str = "auto", model_path: str | Path | None = None) -> str:
    """把 ``auto`` 解析成具体设备；显式请求不可用时降级到 cpu。

    降级而不是抛错：分析任务的可用性优先于加速，缺省路径必须始终能跑。
    """
    requested = (requested or "auto").strip().lower()
    if requested not in SUPPORTED_DEVICES:
        raise ValueError(f"unsupported device: {requested}")
    if requested == "coreml":
        # 这条分支刻意放在 import torch 之前：显式请求 coreml 时不应该再付
        # 3 s 的 torch/ultralytics 启动成本（ORT 只要 0.1–0.2 s）。
        if coreml_available(model_path):
            return "coreml"
        # 不可用时按 auto 重新解析，和 dml「不可用就降级」的既有约定一致。
        requested = "auto"
    if requested != "auto":
        return requested

    # Intel wheels can report MPS available while lacking torchvision NMS.
    if _intel_macos():
        return "cpu"

    if _cuda_possible() and _torch_cuda_available():
        return "cuda"
    if dml_available(model_path):
        return "dml"
    if coreml_available(model_path):
        return "coreml"
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
    if device == "coreml" and not coreml_available(model_path):
        device = "cpu"
    if device == "cuda" and not _torch_cuda_available():
        device = "cpu"
    if device == "mps" and not _torch_mps_available():
        device = "cpu"
    return _remember(device)


def max_batch_for(device: str) -> int:
    """各后端的推荐批大小。

    DML 的 dynamic shape 小批量会退化；CoreML 用的静态模型只接受 ``1×3×640×640``，
    喂第二张会直接 ``INVALID_ARGUMENT``，所以两者都只能单张。
    """
    return {"dml": 1, "coreml": 1, "cpu": 8, "cuda": 16, "mps": 8}.get(device, 8)


def _load_detector(
    model_path: str | Path,
    device: str | None = None,
    **kwargs: Any,
) -> Any:
    """按设备返回检测器：``dml``/``coreml`` 走 ORT，其余走 ultralytics/torch。

    ``device=None`` 时沿用 ``select_device()`` 选定的后端。DirectML 需要的
    ``.onnx``、CoreML 需要的静态 ``.static.onnx`` 缺失，或 ORT 建会话失败时，
    自动退回 torch，并把实际后端写回状态。
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

    if target == "coreml":
        from .onnx_detector import OnnxDetector

        fallback_target = "cpu" if _intel_macos() else "mps"
        onnx_path = static_onnx_path_for(path)
        if onnx_path.is_file():
            # 方形 letterbox 是硬要求：静态模型只吃 1×3×640×640，rect 输入直接报错。
            kwargs.setdefault("max_batch", 1)
            kwargs.setdefault("letterbox_mode", "square")
            try:
                detector = OnnxDetector(onnx_path, device="coreml", **kwargs)
            except TypeError:
                raise
            except Exception as error:
                # 静态模型是可选产物，损坏或 ORT 读不了时不能让整次分析失败。
                print(f"device=coreml failed to load {onnx_path.name} ({error}); falling back to {fallback_target}", file=sys.stderr)
            else:
                if detector.device == "coreml":
                    _remember("coreml")
                    return detector
                # CoreML EP 没建起来时退回 torch；Intel 保持 CPU，其他平台沿用 MPS。
                print(
                    "device=coreml unavailable at session level "
                    f"(providers={detector.provider}); falling back to {fallback_target}",
                    file=sys.stderr,
                )
        else:
            print(
                f"device=coreml skipped: {onnx_path.name} not found "
                f"(run scripts/export_mobile_model.py --imgsz 640 --batch 1); falling back",
                file=sys.stderr,
            )
        target = fallback_target

    try:
        from ultralytics import YOLO
    except (ImportError, OSError) as error:
        # torch 的 DLL 起不来时，CPU 改走 ORT，检测结果和 .pt 一致。
        onnx_path = onnx_path_for(path)
        if target != "cpu" or not onnx_path.is_file():
            raise
        from .onnx_detector import OnnxDetector

        print(f"torch unavailable ({error}); using onnxruntime cpu", file=sys.stderr)
        detector = OnnxDetector(onnx_path, device="cpu", **kwargs)
        _remember(detector.device)
        return detector

    _remember(target if target in {"cuda", "mps"} else "cpu")
    return YOLO(str(path))


def load_detector(model_path, device=None, **kwargs):
    try:
        return _load_detector(model_path, device, **kwargs)
    except (FileNotFoundError, PermissionError):
        raise
    except (ImportError, OSError) as exc:
        raise DetectorRuntimeUnavailable(str(exc)) from exc
    except Exception as exc:
        if is_runtime_failure(str(exc)):
            raise DetectorRuntimeUnavailable(str(exc)) from exc
        raise


def backend_report(model_path: str | Path | None = None) -> dict[str, Any]:
    """给诊断日志/check_runtime 用的后端可用性快照。"""
    report: dict[str, Any] = {
        "torch_cuda": _torch_cuda_available(),
        "torch_mps": _torch_mps_available(),
        "ort_dml": _dml_provider_available(),
        "ort_coreml": _coreml_provider_available(),
        "onnx_model": None,
        "static_onnx": None,
    }
    try:
        import onnxruntime as ort

        report["onnxruntime"] = ort.__version__
    except ImportError:
        report["onnxruntime"] = None
    if model_path is not None:
        onnx_path = onnx_path_for(model_path)
        report["onnx_model"] = str(onnx_path) if onnx_path.is_file() else None
        static_path = static_onnx_path_for(model_path)
        report["static_onnx"] = str(static_path) if static_path.is_file() else None
    return report
