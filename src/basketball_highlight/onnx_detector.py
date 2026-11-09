"""ONNX Runtime 检测器：为桌面端提供 CoreML / DirectML / CPU 推理路径。

这个模块刻意做成 ``ultralytics.YOLO.predict`` 的形状兼容层：
调用方仍然拿 ``result.boxes`` / ``box.cls[0]`` / ``box.conf[0]`` /
``box.xyxy[0].tolist()`` / ``result.names``，因此三个推理脚本不需要改判定逻辑，
只换模型对象即可。

预处理与后处理和 ``ultralytics`` 的 ``.pt`` 推理对齐：同一批画面尺寸相同时用矩形
letterbox（短边补到 32 的倍数），尺寸不同才补成方形；pad 114、INTER_LINEAR、
BGR→RGB、/255、class-aware NMS（IoU 0.7、max_det 300）。方形补边会让小目标和
阈值附近的置信度与线上结果不一致，所以不能固定用方形——**唯一例外是 CoreML**：
它用的静态 ``1×3×640×640`` 模型不接受 rect 输入，必须显式传 ``letterbox_mode="square"``
（见 ``docs/benchmarks/COREML_BACKEND_BENCHMARK_20261025.md``）。
decode 语义与 ``scripts/compare_pt_onnx_frame.py`` 保持一致，那里已与 PT 逐帧对齐过。

注意 DML 的 batch 行为：实测 dynamic batch 下 batch=1 是 2.88 ms/张，batch=2 会塌到
13.9 ms/张。所以本模块默认 ``max_batch=1``，由后端能力决定，不听调用方的 batch 参数。
CoreML 的静态模型喂第二张会直接报错，同样只能单张。
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Any, Iterable, Sequence

import numpy as np

DEFAULT_NAMES = {0: "ball", 1: "hoop"}
PAD_VALUE = 114
STRIDE = 32
NMS_IOU = 0.7
MAX_DET = 300

# 后端默认批大小。DML 的 dynamic shape 路径在小 batch 上会严重退化，
# 只能单张喂；CPU 上批量反而有吞吐收益；CoreML 的静态模型只接受 batch=1。
BACKEND_MAX_BATCH = {"dml": 1, "cpu": 8, "coreml": 1}

# ORT 1.31 的 Python CoreML EP 只认 CPUOnly / CPUAndGPU / CPUAndNeuralEngine，
# 且**区分大小写**：写成 "All" 会被 coreml_options.cc 拒掉、静默回落到纯 CPU
# （实测 51.93 vs 8.26 ms/帧）。神经引擎在这台机器上反而更慢（21.4 vs 8.3 ms），
# 收益来自 Metal，所以固定 CPUAndGPU。
COREML_UNITS = "CPUAndGPU"

LETTERBOX_MODES = ("auto", "square", "rect")


class Box:
    """最小化的单框对象，字段形状与 ultralytics 的 Boxes 一致。"""

    __slots__ = ("cls", "conf", "xyxy")

    def __init__(self, class_id: int, confidence: float, xyxy: Sequence[float]):
        self.cls = [int(class_id)]
        self.conf = [float(confidence)]
        self.xyxy = [np.asarray(xyxy, dtype=np.float32)]


class Result:
    """单张图的检测结果，``boxes`` 可迭代，``names`` 是 class_id → 名称。"""

    __slots__ = ("boxes", "names")

    def __init__(self, boxes: list[Box], names: dict[int, str]):
        self.boxes = boxes
        self.names = names


def letterbox(
    image: np.ndarray, size: int, auto: bool = False,
) -> tuple[np.ndarray, float, int, int]:
    """等比缩放后居中补边，返回 (图, 缩放比, 横向偏移, 纵向偏移)。

    ``auto=False`` 补成 size×size；``auto=True`` 和 ultralytics ``LetterBox(auto=True)``
    一样只补到 ``STRIDE`` 的倍数，例如 1920×1440 → 640×480。
    """
    height, width = image.shape[:2]
    scale = min(size / width, size / height)
    resized_width = max(1, round(width * scale))
    resized_height = max(1, round(height * scale))
    resized = image if (resized_width, resized_height) == (width, height) \
        else _resize(image, resized_width, resized_height)
    canvas_width = math.ceil(resized_width / STRIDE) * STRIDE if auto else size
    canvas_height = math.ceil(resized_height / STRIDE) * STRIDE if auto else size
    canvas = np.full((canvas_height, canvas_width, image.shape[2]), PAD_VALUE, dtype=resized.dtype)
    offset_x = (canvas_width - resized_width) // 2
    offset_y = (canvas_height - resized_height) // 2
    canvas[offset_y:offset_y + resized_height, offset_x:offset_x + resized_width] = resized
    return canvas, scale, offset_x, offset_y


def _resize(image: np.ndarray, width: int, height: int) -> np.ndarray:
    import cv2

    return cv2.resize(image, (width, height), interpolation=cv2.INTER_LINEAR)


def preprocess(
    image: np.ndarray, size: int, auto: bool = False,
) -> tuple[np.ndarray, float, int, int]:
    """BGR HWC → RGB CHW float32/255，附带 letterbox 参数用于反变换。"""
    canvas, scale, offset_x, offset_y = letterbox(image, size, auto)
    rgb = canvas[:, :, ::-1]
    tensor = np.ascontiguousarray(rgb.transpose(2, 0, 1)[None], dtype=np.float32) / 255.0
    return tensor, scale, offset_x, offset_y


def iou_xyxy(left: Sequence[float], right: Sequence[float]) -> float:
    x1 = max(float(left[0]), float(right[0]))
    y1 = max(float(left[1]), float(right[1]))
    x2 = min(float(left[2]), float(right[2]))
    y2 = min(float(left[3]), float(right[3]))
    intersection = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    left_area = max(0.0, float(left[2] - left[0])) * max(0.0, float(left[3] - left[1]))
    right_area = max(0.0, float(right[2] - right[0])) * max(0.0, float(right[3] - right[1]))
    return intersection / max(1e-6, left_area + right_area - intersection)


def decode(
    output: np.ndarray,
    size: int,
    scale: float,
    offset_x: int,
    offset_y: int,
    *,
    conf: float = 0.25,
    iou: float = NMS_IOU,
    max_det: int = MAX_DET,
    agnostic_nms: bool = False,
) -> list[tuple[int, float, list[float]]]:
    """把 YOLO 输出张量解成 [(class_id, confidence, xyxy)]，坐标已反 letterbox。"""
    values = np.asarray(output)
    if values.ndim == 3:
        values = values[0]
    if values.ndim != 2:
        raise ValueError(f"unexpected ONNX output shape: {output.shape}")
    # (4+nc, anchors) → (anchors, 4+nc)。类别数远小于 anchors，用列数判断更稳。
    if values.shape[0] <= values.shape[1]:
        values = values.T
    if values.shape[1] < 5:
        raise ValueError(f"unexpected ONNX output shape: {output.shape}")

    boxes = values[:, :4]
    scores = values[:, 4:]
    class_ids = np.argmax(scores, axis=1)
    confidences = scores[np.arange(scores.shape[0]), class_ids]
    keep = confidences >= conf
    if not np.any(keep):
        return []
    boxes = boxes[keep]
    confidences = confidences[keep]
    class_ids = class_ids[keep]

    xyxy = np.empty_like(boxes, dtype=np.float32)
    xyxy[:, 0] = boxes[:, 0] - boxes[:, 2] / 2
    xyxy[:, 1] = boxes[:, 1] - boxes[:, 3] / 2
    xyxy[:, 2] = boxes[:, 0] + boxes[:, 2] / 2
    xyxy[:, 3] = boxes[:, 1] + boxes[:, 3] / 2

    if agnostic_nms:
        groups: Iterable[np.ndarray] = [np.argsort(-confidences)]
    else:
        order = np.argsort(-confidences)
        groups = [order[class_ids[order] == class_id] for class_id in np.unique(class_ids)]

    picked: list[int] = []
    for group in groups:
        kept: list[int] = []
        for index in group:
            if all(iou_xyxy(xyxy[index], xyxy[other]) < iou for other in kept):
                kept.append(int(index))
                if len(picked) + len(kept) >= max_det:
                    break
        picked.extend(kept)
        if len(picked) >= max_det:
            break
    picked.sort(key=lambda item: -float(confidences[item]))

    results: list[tuple[int, float, list[float]]] = []
    for index in picked[:max_det]:
        left, top, right, bottom = xyxy[index]
        results.append((
            int(class_ids[index]),
            float(confidences[index]),
            [
                round(float((left - offset_x) / scale), 3),
                round(float((top - offset_y) / scale), 3),
                round(float((right - offset_x) / scale), 3),
                round(float((bottom - offset_y) / scale), 3),
            ],
        ))
    return results


def load_names(onnx_path: Path) -> dict[int, str]:
    """读取导出时写下的类别名；缺失时回落到检测器的两类。"""
    sidecar = onnx_path.with_suffix(onnx_path.suffix + ".names.json")
    try:
        payload = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return dict(DEFAULT_NAMES)
    names = payload.get("names") if isinstance(payload, dict) else None
    if isinstance(names, dict):
        try:
            return {int(key): str(value) for key, value in names.items()}
        except (TypeError, ValueError):
            return dict(DEFAULT_NAMES)
    if isinstance(names, list):
        return {index: str(value) for index, value in enumerate(names)}
    return dict(DEFAULT_NAMES)


def _new_session(
    onnx_path: Path, options: Any, providers: list[Any],
):
    """建一个 ORT 会话；单独一层，CPU 回退在测试里可以换掉它。"""
    import onnxruntime as ort

    return ort.InferenceSession(
        str(onnx_path), sess_options=options, providers=providers,
    )


class OnnxDetector:
    """ORT 会话封装，提供 ``predict()`` 以替代 ultralytics 模型对象。"""

    def __init__(
        self,
        onnx_path: str | Path,
        *,
        device: str = "dml",
        imgsz: int = 640,
        max_batch: int | None = None,
        names: dict[int, str] | None = None,
        session_options: Any | None = None,
        letterbox_mode: str = "auto",
    ):
        # 参数校验放在 import onnxruntime 之前:调用方写错参数时不应该因为
        # 机器上没装 ORT 而看到 ImportError。
        if letterbox_mode not in LETTERBOX_MODES:
            raise ValueError(
                f"unsupported letterbox_mode: {letterbox_mode} "
                f"(expected one of {', '.join(LETTERBOX_MODES)})"
            )

        import onnxruntime as ort

        self.onnx_path = Path(onnx_path)
        if not self.onnx_path.is_file():
            raise FileNotFoundError(f"ONNX model not found: {self.onnx_path}")
        self.device = device if device != "auto" else "dml"
        self.imgsz = imgsz
        self.letterbox_mode = letterbox_mode
        self.names = names if names is not None else load_names(self.onnx_path)

        providers = self._providers(self.device)
        options = session_options if session_options is not None else ort.SessionOptions()
        options.log_severity_level = 3
        try:
            self.session = ort.InferenceSession(
                str(self.onnx_path), sess_options=options, providers=providers,
            )
        except Exception:
            # 加速后端建会话失败时退回 CPU，不能让整次分析失败。
            self.session = ort.InferenceSession(
                str(self.onnx_path), sess_options=options,
                providers=["CPUExecutionProvider"],
            )
            self.device = "cpu"
        self.provider = (self.session.get_providers() or ["CPUExecutionProvider"])[0]
        # 加速 EP 可能被静默摘掉（选项非法、模型不支持、机器没有该单元），
        # 这时不能假装还在加速：降级到 cpu，让调用方的日志能看出真相。
        expected = {
            "dml": "DmlExecutionProvider",
            "coreml": "CoreMLExecutionProvider",
        }.get(self.device)
        if expected is not None and self.provider != expected:
            self.device = "cpu"
        model_input = self.session.get_inputs()[0]
        self.input_name = model_input.name
        self.input_shape = tuple(model_input.shape or ())
        self.max_batch = max_batch or BACKEND_MAX_BATCH.get(self.device, 1)
        self.max_batch = max(1, int(self.max_batch))
        # 静态模型（手机端导出的 1×3×640×640）一次只能喂 1 张；固定成更多张的模型每批必须
        # 正好凑满，尾批会失败，只支持单张或动态 batch。
        batch_dim = (model_input.shape or [None])[0]
        if isinstance(batch_dim, int) and batch_dim > 1:
            raise ValueError(
                f"不支持固定 batch={batch_dim} 的 ONNX 模型：{self.onnx_path.name}，"
                "请导出单张或动态 batch 模型（scripts/export_mobile_model.py --dynamic）"
            )
        if batch_dim == 1:
            self.max_batch = 1

    @staticmethod
    def _providers(device: str) -> list[Any]:
        """按请求的设备给出 provider 顺序：只有 dml/coreml 会启用加速 EP。"""
        if device == "dml":
            return ["DmlExecutionProvider", "CPUExecutionProvider"]
        if device == "coreml":
            return [
                (
                    "CoreMLExecutionProvider",
                    {
                        "ModelFormat": "MLProgram",
                        "MLComputeUnits": COREML_UNITS,
                        "SpecializationStrategy": "FastPrediction",
                    },
                ),
                "CPUExecutionProvider",
            ]
        return ["CPUExecutionProvider"]

    @property
    def batch_size(self) -> int:
        return self.max_batch

    def predict(
        self,
        images: Any,
        *,
        conf: float = 0.25,
        iou: float = NMS_IOU,
        imgsz: int | None = None,
        max_det: int = MAX_DET,
        agnostic_nms: bool = False,
        rect: bool = True,
        batch: int = 1,
        verbose: bool = False,
        **_ignored: Any,
    ) -> list[Result]:
        """对一批裁剪图推理，返回与输入顺序一致的 ``Result`` 列表。"""
        size = int(imgsz or self.imgsz)
        frames = self._as_list(images)
        if not frames:
            return []

        results: list[Result] = []
        # 后端自定批大小：DML 只吃单张，CPU 可以多吃几张。
        step = max(1, min(self.max_batch, len(frames)))
        for start in range(0, len(frames), step):
            chunk = frames[start:start + step]
            results.extend(self._predict_chunk(chunk, size, conf, iou, max_det, agnostic_nms, rect))
        return results

    def _predict_chunk(
        self, frames: list[np.ndarray], size: int,
        conf: float, iou: float, max_det: int, agnostic_nms: bool, rect: bool = True,
    ) -> list[Result]:
        tensors = []
        meta = []
        # 和 ultralytics 一样：rect=True 且整批尺寸相同才用矩形输入，否则补成方形。
        # 分析脚本都传 rect=False，和 .pt 一样喂 640×640；CoreML 的静态模型只接受
        # size×size，靠 letterbox_mode="square" 显式压住。
        if self.letterbox_mode == "square":
            auto = False
        elif self.letterbox_mode == "rect":
            auto = True
        else:
            auto = rect and len({frame.shape for frame in frames}) == 1
        for frame in frames:
            tensor, scale, offset_x, offset_y = preprocess(frame, size, auto)
            tensors.append(tensor)
            meta.append((scale, offset_x, offset_y))
        batch = np.concatenate(tensors, axis=0) if len(tensors) > 1 else tensors[0]
        self._check_input_shape(batch)
        try:
            outputs = self.session.run(None, {self.input_name: batch})
        except Exception as error:
            # 非 CPU 后端在遇到坏帧/驱动异常时会抛错，而且错误信息常被当作
            # UTF-8 解（典型：GBK 驱动消息触发 UnicodeDecodeError 0xb2）。
            # 一次坏帧不该让整次分析失败：退回 CPU 重建会话重跑一次，并记下
            # 原始异常 repr 便于定位。
            if self.provider == "CPUExecutionProvider":
                raise
            print(
                f"inference on {self.provider} failed ({error!r}); "
                "rebuilding a CPU session and retrying",
                file=sys.stderr,
            )
            self._switch_to_cpu()
            try:
                outputs = self.session.run(None, {self.input_name: batch})
            except Exception as cpu_error:
                print(
                    f"inference on CPU also failed ({cpu_error!r}); giving up",
                    file=sys.stderr,
                )
                raise error from cpu_error
        raw = outputs[0]

        results: list[Result] = []
        # 只有真的喂了多张、且输出带 batch 维度时才按下标取；否则整份输出就是这一张的。
        batched = raw.ndim >= 3 and raw.shape[0] == len(meta) and len(meta) > 1
        for index, (scale, offset_x, offset_y) in enumerate(meta):
            single = raw[index:index + 1] if batched else raw
            detections = decode(
                single, size, scale, offset_x, offset_y,
                conf=conf, iou=iou, max_det=max_det, agnostic_nms=agnostic_nms,
            )
            boxes = [Box(class_id, score, xyxy) for class_id, score, xyxy in detections]
            results.append(Result(boxes, self.names))
        return results

    def _switch_to_cpu(self) -> None:
        """丢掉加速后端会话，换成 CPU 会话重建（回退只做一次）。"""
        import onnxruntime as ort

        options = ort.SessionOptions()
        options.log_severity_level = 3
        self.session = _new_session(
            self.onnx_path, options, ["CPUExecutionProvider"],
        )
        self.device = "cpu"
        self.provider = (self.session.get_providers() or ["CPUExecutionProvider"])[0]
        model_input = self.session.get_inputs()[0]
        self.input_name = model_input.name
        self.input_shape = tuple(model_input.shape or ())
        self.max_batch = max(1, BACKEND_MAX_BATCH["cpu"])

    def _check_input_shape(self, batch: np.ndarray) -> None:
        """静态模型收到不匹配的输入时给出人话错误，而不是把 ORT 的报错原样丢上去。

        典型触发场景：拿静态 ``1×3×640×640`` 的模型喂 rect（640×480）或多张图。
        """
        model_shape = getattr(self, "input_shape", ())
        for axis, expected in enumerate(model_shape):
            # 动态维度在 ORT 里是字符串或 0/None，只校验静态的那几维。
            if not isinstance(expected, int) or expected <= 0:
                continue
            if axis >= batch.ndim or batch.shape[axis] == expected:
                continue
            raise ValueError(
                f"{self.onnx_path.name} 只接受固定输入 {model_shape}，"
                f"本次送入 {batch.shape}："
                "CoreML 路径要用 640×640 方形 letterbox（letterbox_mode='square'），"
                "并且一次只送一张。"
            )

    @staticmethod
    def _as_list(images: Any) -> list[np.ndarray]:
        if isinstance(images, np.ndarray):
            if images.ndim == 3:
                return [images]
            return [row for row in images]
        if isinstance(images, (list, tuple)):
            return [item for item in images if item is not None]
        raise TypeError(f"unsupported image container: {type(images)!r}")
