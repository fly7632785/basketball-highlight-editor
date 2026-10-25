"""DirectML/ONNX 推理层的单元测试。

这些用例不依赖 onnxruntime 和模型文件:预处理、decode、NMS、批大小策略都能用
合成数据验证。真机一致性由 `scripts/compare_pt_onnx_frame.py` 和端到端回放保证。
"""
from __future__ import annotations

import sys

import numpy as np
import pytest

from basketball_highlight import inference
from basketball_highlight.onnx_detector import (
    OnnxDetector,
    Result,
    decode,
    letterbox,
    preprocess,
)


def test_letterbox_pads_wide_image_to_square():
    image = np.zeros((100, 200, 3), dtype=np.uint8)
    canvas, scale, offset_x, offset_y = letterbox(image, 640)

    assert canvas.shape == (640, 640, 3)
    assert scale == pytest.approx(640 / 200)
    assert offset_x == 0
    assert offset_y == (640 - 320) // 2
    # 补边用 114,和 ultralytics 的 letterbox 一致。
    assert int(canvas[0, 0, 0]) == 114
    assert int(canvas[offset_y + 1, 1, 0]) == 0


def test_letterbox_auto_only_pads_to_the_stride_like_ultralytics():
    # 1920×1440 这样的画面线上实际送进模型的是 640×480，不是 640×640。
    image = np.zeros((1440, 1920, 3), dtype=np.uint8)
    canvas, scale, offset_x, offset_y = letterbox(image, 640, auto=True)

    assert canvas.shape == (480, 640, 3)
    assert scale == pytest.approx(640 / 1920)
    assert (offset_x, offset_y) == (0, 0)

    odd = np.zeros((100, 200, 3), dtype=np.uint8)
    canvas, _, _, offset_y = letterbox(odd, 650, auto=True)
    # 650×325 → 补到 32 的倍数 672×352，补边居中。
    assert canvas.shape == (352, 672, 3)
    assert offset_y == (352 - 325) // 2


def test_preprocess_returns_chw_float_tensor_in_rgb():
    image = np.zeros((10, 20, 3), dtype=np.uint8)
    image[:, :, 0] = 255  # BGR 蓝
    tensor, scale, _, offset_y = preprocess(image, 64)

    assert tensor.shape == (1, 3, 64, 64)
    assert tensor.dtype == np.float32
    assert tensor.max() <= 1.0
    assert scale == pytest.approx(64 / 20)
    # 补边是 114/255,三通道一致。
    assert tensor[0, 0].max() == pytest.approx(114 / 255)
    # 内容区中心: BGR 的蓝通道在 RGB 里排最后。
    center = tensor[0, :, 32, 32]
    assert center.tolist() == pytest.approx([0.0, 0.0, 1.0])
    assert offset_y == (64 - 32) // 2


def _output(boxes, size=640, min_anchors=10):
    """构造 (1, 4+nc, anchors) 的 YOLO 输出,boxes=[(cx,cy,w,h,scores...)]。

    anchors 补到 min_anchors:真实输出是 8400,这里只要求"anchors 远多于通道数"
    这个形态,才能让 decode 的转置判断生效。
    """
    channels = 4 + len(boxes[0][4]) if boxes else 6
    anchors = max(min_anchors, len(boxes))
    tensor = np.zeros((1, channels, anchors), dtype=np.float32)
    for index, box in enumerate(boxes):
        tensor[0, :4, index] = box[:4]
        tensor[0, 4:, index] = box[4]
    return tensor


def test_decode_maps_box_back_to_image_coordinates():
    # 一张 200x100 的图被 letterbox 到 640:scale=3.2,y 方向补边 160。
    output = _output([(320.0, 320.0, 32.0, 32.0, [0.9, 0.1])])
    detections = decode(output, 640, 3.2, 0, 160, conf=0.5)
    assert len(detections) == 1
    class_id, confidence, xyxy = detections[0]
    assert class_id == 0
    assert confidence == pytest.approx(0.9)
    # x: 304..336 → 95..105;y: (304-160)..(336-160) → 45..55
    assert xyxy == pytest.approx([95.0, 45.0, 105.0, 55.0])


def test_decode_applies_class_aware_nms():
    # 同类别重叠 → 只留分高的;不同类别重叠 → 两个都留。
    overlap = (320.0, 320.0, 40.0, 40.0)
    same_class = _output([
        overlap + ([0.9, 0.0],),
        (321.0, 320.0, 40.0, 40.0) + ([0.8, 0.0],),
    ])
    assert len(decode(same_class, 640, 1.0, 0, 0, conf=0.1)) == 1

    cross_class = _output([
        overlap + ([0.9, 0.0],),
        overlap + ([0.0, 0.85],),
    ])
    assert len(decode(cross_class, 640, 1.0, 0, 0, conf=0.1)) == 2


def test_decode_respects_confidence_and_max_det():
    boxes = [((10.0 * index), 320.0, 20.0, 20.0, [0.5 + index * 0.01, 0.0]) for index in range(10)]
    boxes.append((600.0, 320.0, 20.0, 20.0, [0.05, 0.0]))
    output = _output(boxes)

    assert all(item[1] >= 0.5 for item in decode(output, 640, 1.0, 0, 0, conf=0.5))
    assert len(decode(output, 640, 1.0, 0, 0, conf=0.05, max_det=3)) == 3


def test_decode_returns_empty_when_nothing_passes_threshold():
    output = _output([(100.0, 100.0, 10.0, 10.0, [0.01, 0.0])])
    assert decode(output, 640, 1.0, 0, 0, conf=0.5) == []


def test_result_shim_matches_ultralytics_access_pattern():
    detector = object.__new__(OnnxDetector)
    detector.names = {0: "ball", 1: "hoop"}
    result = Result([], detector.names)

    assert result.names[0] == "ball"
    assert len(result.boxes) == 0

    from basketball_highlight.onnx_detector import Box

    box = Box(1, 0.75, [1.0, 2.0, 3.0, 4.0])
    assert int(box.cls[0]) == 1
    assert float(box.conf[0]) == pytest.approx(0.75)
    assert box.xyxy[0].tolist() == pytest.approx([1.0, 2.0, 3.0, 4.0])


class _FakeSession:
    def __init__(self, batch_outputs: int):
        self.calls: list[int] = []
        self.shapes: list[tuple[int, ...]] = []
        self.batch_outputs = batch_outputs

    def run(self, _outputs, feed):
        batch = list(feed.values())[0].shape[0]
        self.calls.append(batch)
        self.shapes.append(tuple(list(feed.values())[0].shape))
        # (batch, 4+2, anchors) 的真实形态,anchors 给足才能走转置分支。
        return [np.zeros((batch, 6, 10), dtype=np.float32)]


def _fake_detector(max_batch: int) -> OnnxDetector:
    detector = object.__new__(OnnxDetector)
    detector.session = _FakeSession(max_batch)
    detector.input_name = "images"
    detector.imgsz = 640
    detector.names = {0: "ball"}
    detector.device = "dml" if max_batch == 1 else "cpu"
    detector.max_batch = max_batch
    return detector


def test_predict_feeds_dml_one_image_per_run():
    detector = _fake_detector(1)
    frames = [np.zeros((64, 64, 3), dtype=np.uint8) for _ in range(3)]
    results = detector.predict(frames, conf=0.5)
    assert len(results) == 3
    assert detector.session.calls == [1, 1, 1]


def test_predict_batches_more_images_on_cpu():
    detector = _fake_detector(8)
    frames = [np.zeros((64, 64, 3), dtype=np.uint8) for _ in range(3)]
    detector.predict(frames, conf=0.5)
    assert detector.session.calls == [3]


def test_predict_uses_rectangular_input_when_a_batch_shares_one_size():
    detector = _fake_detector(8)
    detector.predict([np.zeros((1440, 1920, 3), dtype=np.uint8)] * 2, conf=0.5)
    assert detector.session.shapes == [(2, 3, 480, 640)]


def test_predict_pads_mixed_sizes_to_a_square_batch():
    detector = _fake_detector(8)
    detector.predict(
        [np.zeros((1440, 1920, 3), dtype=np.uint8), np.zeros((720, 960, 3), dtype=np.uint8)],
        conf=0.5,
    )
    assert detector.session.shapes == [(2, 3, 640, 640)]


def test_predict_accepts_single_image():
    detector = _fake_detector(1)
    results = detector.predict(np.zeros((64, 64, 3), dtype=np.uint8))
    assert len(results) == 1


def test_resolve_device_prefers_cuda_then_dml(monkeypatch):
    monkeypatch.setattr(inference, "_torch_cuda_available", lambda: True)
    monkeypatch.setattr(inference, "_dml_provider_available", lambda: True)
    assert inference.resolve_device("auto") == "cuda"

    monkeypatch.setattr(inference, "_torch_cuda_available", lambda: False)
    monkeypatch.setattr(inference, "_torch_mps_available", lambda: True)
    assert inference.resolve_device("auto") == "dml"

    monkeypatch.setattr(inference, "_dml_provider_available", lambda: False)
    assert inference.resolve_device("auto") == "mps"


def test_resolve_device_falls_back_to_cpu(monkeypatch):
    monkeypatch.setattr(inference, "_torch_cuda_available", lambda: False)
    monkeypatch.setattr(inference, "_torch_mps_available", lambda: False)
    monkeypatch.setattr(inference, "_dml_provider_available", lambda: False)
    assert inference.resolve_device("auto") == "cpu"
    assert inference.select_device("dml") == "cpu"
    assert inference.current_device() == "cpu"


def test_load_detector_falls_back_to_torch_when_onnx_missing(tmp_path, monkeypatch):
    model = tmp_path / "model.pt"
    model.write_bytes(b"pt")

    fake_ultralytics = type(sys)("ultralytics")
    fake_ultralytics.YOLO = lambda path: ("yolo", path)

    monkeypatch.setitem(sys.modules, "ultralytics", fake_ultralytics)
    monkeypatch.setattr(inference, "_dml_provider_available", lambda: True)
    inference.select_device("dml")

    detector = inference.load_detector(model)
    assert detector == ("yolo", str(model))
    assert inference.current_device() == "cpu"
