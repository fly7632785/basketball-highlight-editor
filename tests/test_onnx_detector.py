"""DirectML/ONNX 推理层的单元测试。

这些用例不依赖 onnxruntime 和模型文件:预处理、decode、NMS、批大小策略都能用
合成数据验证。真机一致性由 `scripts/compare_pt_onnx_frame.py` 和端到端回放保证。
"""
from __future__ import annotations

import sys
from pathlib import Path

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


def _fake_detector(max_batch: int, letterbox_mode: str = "auto") -> OnnxDetector:
    detector = object.__new__(OnnxDetector)
    detector.session = _FakeSession(max_batch)
    detector.input_name = "images"
    detector.imgsz = 640
    detector.names = {0: "ball"}
    detector.device = "dml" if max_batch == 1 else "cpu"
    detector.max_batch = max_batch
    detector.letterbox_mode = letterbox_mode
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


def test_predict_keeps_the_input_square_when_rect_is_off():
    detector = _fake_detector(8)
    detector.predict([np.zeros((1440, 1920, 3), dtype=np.uint8)] * 2, conf=0.5, rect=False)
    assert detector.session.shapes == [(2, 3, 640, 640)]


def test_predict_pads_mixed_sizes_to_a_square_batch():
    detector = _fake_detector(8)
    detector.predict(
        [np.zeros((1440, 1920, 3), dtype=np.uint8), np.zeros((720, 960, 3), dtype=np.uint8)],
        conf=0.5,
    )
    assert detector.session.shapes == [(2, 3, 640, 640)]


def test_predict_square_letterbox_overrides_the_rect_default():
    # 回归本次的必改点:CoreML 的静态模型只吃 1×3×640×640,
    # 同尺寸批默认会走 rect(640×480),必须被 letterbox_mode 压成方形。
    detector = _fake_detector(8, letterbox_mode="square")
    detector.predict([np.zeros((1440, 1920, 3), dtype=np.uint8)] * 2, conf=0.5)
    assert detector.session.shapes == [(2, 3, 640, 640)]


def test_static_model_shape_mismatch_raises_a_readable_error():
    detector = _fake_detector(1)
    detector.input_shape = (1, 3, 640, 640)
    detector.onnx_path = Path("bball_model.static.onnx")
    with pytest.raises(ValueError) as error:
        detector.predict([np.zeros((1440, 1920, 3), dtype=np.uint8)] * 2, conf=0.5)
    message = str(error.value)
    assert "640" in message
    assert "letterbox_mode" in message


def test_unknown_letterbox_mode_is_rejected():
    from basketball_highlight.onnx_detector import OnnxDetector as Detector

    with pytest.raises(ValueError):
        Detector("missing.onnx", letterbox_mode="stretch")


def test_predict_accepts_single_image():
    detector = _fake_detector(1)
    results = detector.predict(np.zeros((64, 64, 3), dtype=np.uint8))
    assert len(results) == 1


def test_resolve_device_prefers_cuda_then_dml(monkeypatch):
    # 平台门禁:macOS 没有 CUDA,先判平台就能省掉一次 import torch。
    monkeypatch.setattr(inference, "_cuda_possible", lambda: True)
    monkeypatch.setattr(inference, "_torch_cuda_available", lambda: True)
    monkeypatch.setattr(inference, "_dml_provider_available", lambda: True)
    assert inference.resolve_device("auto") == "cuda"

    monkeypatch.setattr(inference, "_torch_cuda_available", lambda: False)
    monkeypatch.setattr(inference, "_torch_mps_available", lambda: True)
    assert inference.resolve_device("auto") == "dml"

    monkeypatch.setattr(inference, "_dml_provider_available", lambda: False)
    monkeypatch.setattr(inference, "_coreml_provider_available", lambda: False)
    assert inference.resolve_device("auto") == "mps"


def test_resolve_device_puts_coreml_before_mps(tmp_path, monkeypatch):
    # 阶段 2:auto 链是 cuda > dml > coreml > mps > cpu。
    monkeypatch.setattr(inference, "_cuda_possible", lambda: True)
    monkeypatch.setattr(inference, "_torch_cuda_available", lambda: False)
    monkeypatch.setattr(inference, "_dml_provider_available", lambda: False)
    monkeypatch.setattr(inference, "_torch_mps_available", lambda: True)
    monkeypatch.setattr(inference, "_coreml_experiment_scope", lambda: True)
    monkeypatch.setattr(inference, "_coreml_provider_available", lambda: True)

    # 缺静态模型时仍然回落 mps:不能把"装了 ORT"当成"能跑 coreml"。
    missing = tmp_path / "bball_model.pt"
    missing.write_bytes(b"pt")
    assert inference.resolve_device("auto", missing) == "mps"

    (tmp_path / "bball_model.static.onnx").write_bytes(b"onnx")
    assert inference.resolve_device("auto", missing) == "coreml"


def test_auto_on_macos_does_not_probe_torch_when_coreml_wins(tmp_path, monkeypatch):
    def explode():
        raise AssertionError("coreml 已经可用时,auto 不应该再 import torch")

    # 这条用例模拟的是 macOS:那里 _cuda_possible() 本来就是 False(没有 CUDA 版 torch),
    # 所以 auto 不会去探 CUDA。必须显式钉住,否则在 Linux 上跑会真的去探 CUDA。
    monkeypatch.setattr(inference, "_cuda_possible", lambda: False)
    monkeypatch.setattr(inference, "_torch_cuda_available", explode)
    monkeypatch.setattr(inference, "_torch_mps_available", explode)
    monkeypatch.setattr(inference, "_dml_provider_available", lambda: False)
    monkeypatch.setattr(inference, "_coreml_experiment_scope", lambda: True)
    monkeypatch.setattr(inference, "_coreml_provider_available", lambda: True)
    model = tmp_path / "bball_model.pt"
    model.write_bytes(b"pt")
    (tmp_path / "bball_model.static.onnx").write_bytes(b"onnx")

    assert inference.select_device("auto", model) == "coreml"


def test_resolve_device_falls_back_to_cpu(monkeypatch):
    monkeypatch.setattr(inference, "_cuda_possible", lambda: True)
    monkeypatch.setattr(inference, "_torch_cuda_available", lambda: False)
    monkeypatch.setattr(inference, "_torch_mps_available", lambda: False)
    monkeypatch.setattr(inference, "_dml_provider_available", lambda: False)
    monkeypatch.setattr(inference, "_coreml_provider_available", lambda: False)
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


def _imports_fail_with_oserror(monkeypatch, *names):
    import builtins

    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name.split(".")[0] in names:
            raise OSError("[WinError 1114] 动态链接库(DLL)初始化例程失败。")
        return real_import(name, *args, **kwargs)

    for name in names:
        monkeypatch.delitem(sys.modules, name, raising=False)
    monkeypatch.setattr(builtins, "__import__", fake_import)


def test_a_broken_torch_dll_counts_as_no_cuda(monkeypatch):
    _imports_fail_with_oserror(monkeypatch, "torch")
    inference._torch_cuda_available.cache_clear()
    inference._torch_mps_available.cache_clear()
    try:
        assert inference._torch_cuda_available() is False
        assert inference._torch_mps_available() is False
    finally:
        inference._torch_cuda_available.cache_clear()
        inference._torch_mps_available.cache_clear()


def test_cpu_uses_onnxruntime_when_torch_cannot_load(tmp_path, monkeypatch):
    model = tmp_path / "model.pt"
    model.write_bytes(b"pt")
    (tmp_path / "model.onnx").write_bytes(b"onnx")

    from basketball_highlight import onnx_detector

    class FakeOnnx:
        def __init__(self, path, *, device, **kwargs):
            self.path, self.device = path, device

    monkeypatch.setattr(onnx_detector, "OnnxDetector", FakeOnnx)
    _imports_fail_with_oserror(monkeypatch, "ultralytics", "torch")

    detector = inference.load_detector(model, device="cpu")
    assert (detector.path, detector.device) == (tmp_path / "model.onnx", "cpu")
    assert inference.current_device() == "cpu"


def test_a_broken_torch_without_onnx_still_reports_the_error(tmp_path, monkeypatch):
    model = tmp_path / "model.pt"
    model.write_bytes(b"pt")
    _imports_fail_with_oserror(monkeypatch, "ultralytics", "torch")

    with pytest.raises(inference.DetectorRuntimeUnavailable, match="1114"):
        inference.load_detector(model, device="cpu")


def _detector_for_model_input(tmp_path, monkeypatch, batch_dim):
    """注入假的 onnxruntime 跑真实的 OnnxDetector.__init__，不依赖可选的 ORT 包。"""
    model = tmp_path / "model.onnx"
    model.write_bytes(b"onnx")

    class Session:
        def __init__(self, path, sess_options=None, providers=None):
            pass

        def get_providers(self):
            return ["CPUExecutionProvider"]

        def get_inputs(self):
            return [type("Input", (), {"name": "images", "shape": [batch_dim, 3, 640, 640]})()]

    fake_ort = type(sys)("onnxruntime")
    fake_ort.InferenceSession = Session
    fake_ort.SessionOptions = lambda: type("Options", (), {})()
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_ort)
    return OnnxDetector(model, device="cpu", names={0: "ball"})


@pytest.mark.parametrize(("batch_dim", "expected"), [(1, 1), ("batch", 8)])
def test_a_single_image_model_feeds_one_image_at_a_time(tmp_path, monkeypatch, batch_dim, expected):
    assert _detector_for_model_input(tmp_path, monkeypatch, batch_dim).max_batch == expected


def test_a_model_fixed_to_several_images_is_rejected_up_front(tmp_path, monkeypatch):
    with pytest.raises(ValueError, match="batch=2"):
        _detector_for_model_input(tmp_path, monkeypatch, 2)


def test_coreml_providers_use_a_legal_compute_units_value():
    # 回归:"All" 是 Rust 侧才有的枚举值,Python 侧写成 "All" 会被静默摘掉 EP,
    # 回落到纯 CPU(实测慢 6 倍)且不报错,所以这里盯死合法取值。
    providers = OnnxDetector._providers("coreml")
    assert providers[0][0] == "CoreMLExecutionProvider"
    assert providers[-1] == "CPUExecutionProvider"
    options = providers[0][1]
    assert options["ModelFormat"] == "MLProgram"
    assert options["MLComputeUnits"] in {"CPUOnly", "CPUAndGPU", "CPUAndNeuralEngine"}
    assert options["MLComputeUnits"] != "All"
    # 神经引擎实测更慢(21.4 vs 8.3 ms/帧),收益来自 Metal。
    assert options["MLComputeUnits"] == "CPUAndGPU"


def test_coreml_is_single_image_per_run():
    from basketball_highlight.onnx_detector import BACKEND_MAX_BATCH

    assert BACKEND_MAX_BATCH["coreml"] == 1
    assert inference.max_batch_for("coreml") == 1


def test_static_onnx_path_for_keeps_onnx_and_renames_pt():
    assert inference.static_onnx_path_for("/m/bball_model.pt") == Path("/m/bball_model.static.onnx")
    onnx = Path("/m/bball_model.onnx")
    assert inference.static_onnx_path_for(onnx) == onnx


def test_coreml_available_needs_the_provider(monkeypatch):
    monkeypatch.setattr(inference, "_coreml_experiment_scope", lambda: True)
    monkeypatch.setattr(inference, "_coreml_provider_available", lambda: False)
    assert inference.coreml_available() is False

    monkeypatch.setattr(inference, "_coreml_provider_available", lambda: True)
    assert inference.coreml_available() is True


def test_coreml_available_needs_the_static_model(tmp_path, monkeypatch):
    monkeypatch.setattr(inference, "_coreml_experiment_scope", lambda: True)
    monkeypatch.setattr(inference, "_coreml_provider_available", lambda: True)
    model = tmp_path / "bball_model.pt"
    model.write_bytes(b"pt")

    # 动态 batch 的 bball_model.onnx 存在也不算数:CoreML 上它慢 4 倍。
    (tmp_path / "bball_model.onnx").write_bytes(b"onnx")
    assert inference.coreml_available(model) is False

    (tmp_path / "bball_model.static.onnx").write_bytes(b"onnx")
    assert inference.coreml_available(model) is True


def test_select_device_coreml_skips_torch_probes(tmp_path, monkeypatch):
    # 显式 coreml 的价值一半在省掉 import torch(3 s),所以这条路径不能碰 torch 探测。
    def explode():
        raise AssertionError("coreml 路径不应该探测 torch")

    monkeypatch.setattr(inference, "_coreml_experiment_scope", lambda: True)
    monkeypatch.setattr(inference, "_coreml_provider_available", lambda: True)
    monkeypatch.setattr(inference, "_torch_cuda_available", explode)
    monkeypatch.setattr(inference, "_torch_mps_available", explode)
    model = tmp_path / "bball_model.pt"
    model.write_bytes(b"pt")
    (tmp_path / "bball_model.static.onnx").write_bytes(b"onnx")

    assert inference.select_device("coreml", model) == "coreml"
    assert inference.current_device() == "coreml"


def test_select_device_coreml_degrades_when_model_missing(tmp_path, monkeypatch):
    monkeypatch.setattr(inference, "_coreml_experiment_scope", lambda: True)
    monkeypatch.setattr(inference, "_coreml_provider_available", lambda: True)
    monkeypatch.setattr(inference, "_dml_provider_available", lambda: False)
    monkeypatch.setattr(inference, "_torch_cuda_available", lambda: False)
    monkeypatch.setattr(inference, "_torch_mps_available", lambda: True)
    model = tmp_path / "bball_model.pt"
    model.write_bytes(b"pt")

    # 缺静态模型时不抛错,按 auto 的优先级降级。
    assert inference.select_device("coreml", model) == "mps"


def test_select_device_degrades_to_the_auto_chain_without_coreml(tmp_path, monkeypatch):
    # coreml 不可用(没装 ORT/缺静态模型)时按 auto 的优先级走,不抛错。
    monkeypatch.setattr(inference, "_coreml_experiment_scope", lambda: True)
    monkeypatch.setattr(inference, "_coreml_provider_available", lambda: False)
    monkeypatch.setattr(inference, "_dml_provider_available", lambda: False)
    monkeypatch.setattr(inference, "_cuda_possible", lambda: True)
    monkeypatch.setattr(inference, "_torch_cuda_available", lambda: False)
    monkeypatch.setattr(inference, "_torch_mps_available", lambda: True)
    model = tmp_path / "bball_model.pt"
    model.write_bytes(b"pt")

    assert inference.select_device("coreml", model) == "mps"


def test_coreml_that_fails_to_build_a_session_falls_back_to_mps(tmp_path, monkeypatch):
    model = tmp_path / "bball_model.pt"
    model.write_bytes(b"pt")
    (tmp_path / "bball_model.static.onnx").write_bytes(b"onnx")

    from basketball_highlight import onnx_detector

    class CpuOnly:
        provider = "CPUExecutionProvider"

        def __init__(self, path, *, device, **kwargs):
            self.device = "cpu"

    fake_ultralytics = type(sys)("ultralytics")
    fake_ultralytics.YOLO = lambda path: ("yolo", path)
    monkeypatch.setattr(onnx_detector, "OnnxDetector", CpuOnly)
    monkeypatch.setitem(sys.modules, "ultralytics", fake_ultralytics)

    assert inference.load_detector(model, device="coreml") == ("yolo", str(model))
    assert inference.current_device() == "mps"


def _coreml_factory_case(tmp_path, monkeypatch, error):
    model = tmp_path / "bball_model.pt"
    model.write_bytes(b"pt")
    (tmp_path / "bball_model.static.onnx").write_bytes(b"not a model")

    from basketball_highlight import onnx_detector

    def broken(path, *, device, **kwargs):
        raise error

    fake_ultralytics = type(sys)("ultralytics")
    fake_ultralytics.YOLO = lambda path: ("yolo", path)
    monkeypatch.setattr(onnx_detector, "OnnxDetector", broken)
    monkeypatch.setitem(sys.modules, "ultralytics", fake_ultralytics)
    return model


def test_a_static_model_that_cannot_be_loaded_falls_back_to_mps(tmp_path, monkeypatch):
    model = _coreml_factory_case(tmp_path, monkeypatch, RuntimeError("InvalidProtobuf"))

    assert inference.load_detector(model, device="coreml") == ("yolo", str(model))
    assert inference.current_device() == "mps"


def test_a_wrong_call_to_the_coreml_detector_is_not_swallowed(tmp_path, monkeypatch):
    model = _coreml_factory_case(tmp_path, monkeypatch, TypeError("unexpected keyword"))

    with pytest.raises(TypeError):
        inference.load_detector(model, device="coreml")


def test_cpu_can_fall_back_after_a_torch_importerror(tmp_path, monkeypatch):
    import builtins
    from basketball_highlight import onnx_detector

    model = tmp_path / 'model.pt'
    model.write_bytes(b'pt')
    model.with_suffix('.onnx').write_bytes(b'onnx')
    original_import = builtins.__import__

    def fail_torch(name, *args, **kwargs):
        if name == 'ultralytics':
            raise ImportError('torch import unavailable')
        return original_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, '__import__', fail_torch)
    monkeypatch.setattr(onnx_detector, 'OnnxDetector',
                        lambda path, **kwargs: type('Detector', (), {'device': 'cpu'})())
    assert inference.load_detector(model, device='cpu').device == 'cpu'


@pytest.mark.parametrize('error_type', [ImportError, OSError])
@pytest.mark.parametrize('device', ['cpu', 'dml', 'coreml'])
def test_torch_and_ort_failures_have_a_final_runtime_error(tmp_path, monkeypatch, error_type, device):
    import builtins
    from basketball_highlight import onnx_detector

    model = tmp_path / 'model.pt'
    model.write_bytes(b'pt')
    model.with_suffix('.onnx').write_bytes(b'onnx')
    (tmp_path / 'model.static.onnx').write_bytes(b'onnx')
    original_import = builtins.__import__

    def fail_torch(name, *args, **kwargs):
        if name == 'ultralytics':
            raise error_type('torch runtime unavailable')
        return original_import(name, *args, **kwargs)

    def fail_ort(*args, **kwargs):
        raise error_type('onnxruntime DLL load failed')

    monkeypatch.setattr(builtins, '__import__', fail_torch)
    monkeypatch.setattr(onnx_detector, 'OnnxDetector', fail_ort)
    with pytest.raises(inference.DetectorRuntimeUnavailable) as failure:
        inference.load_detector(model, device=device)
    assert isinstance(failure.value.__cause__, error_type)


def _ort_with_a_failing_dml_session(tmp_path, monkeypatch, *, cpu_fails):
    """注入假的 onnxruntime：DML 会话 run 就抛 UnicodeDecodeError，CPU 会话正常。"""
    model = tmp_path / "model.onnx"
    model.write_bytes(b"onnx")
    calls: list[str] = []

    def output():
        values = np.zeros((1, 6, 20), dtype=np.float32)
        values[0, 0, 0] = 320.0
        values[0, 1, 0] = 320.0
        values[0, 2, 0] = 100.0
        values[0, 3, 0] = 100.0
        values[0, 4, 0] = 0.9   # ball
        values[0, 5, 0] = 0.05  # hoop
        return [values]

    class Session:
        def __init__(self, path, sess_options=None, providers=None):
            self.providers = list(providers or [])
            calls.append(self.providers[0])

        def get_providers(self):
            return self.providers

        def get_inputs(self):
            return [type("Input", (), {"name": "images", "shape": ["batch", 3, "height", "width"]})()]

        def run(self, output_names, feeds):
            if self.providers[0] != "CPUExecutionProvider":
                # 复现真机现象：GBK 的驱动错误信息被当成 UTF-8 解。
                raise UnicodeDecodeError("utf-8", b"\xb2\xe2", 0, 1, "invalid start byte")
            if cpu_fails:
                raise RuntimeError("cpu run failed")
            return output()

    fake_ort = type(sys)("onnxruntime")
    fake_ort.InferenceSession = Session
    fake_ort.SessionOptions = lambda: type("Options", (), {})()
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_ort)
    return OnnxDetector(model, device="dml", names={0: "ball", 1: "hoop"}), calls


def test_a_dml_run_failure_rebuilds_a_cpu_session_and_retries(tmp_path, monkeypatch, capsys):
    detector, calls = _ort_with_a_failing_dml_session(
        tmp_path, monkeypatch, cpu_fails=False,
    )
    image = np.zeros((64, 64, 3), dtype=np.uint8)

    results = detector.predict([image], imgsz=64)

    assert calls == ["DmlExecutionProvider", "CPUExecutionProvider"]
    assert detector.device == "cpu"
    assert detector.provider == "CPUExecutionProvider"
    assert len(results) == 1
    assert [box.cls for box in results[0].boxes] == [[0]]
    # 原始异常要原样记下来，否则只能看到一句「推理失败」。
    stderr = capsys.readouterr().err
    assert "UnicodeDecodeError" in stderr
    assert "invalid start byte" in stderr


def test_a_cpu_run_failure_after_the_fallback_is_raised_unchanged(tmp_path, monkeypatch):
    detector, calls = _ort_with_a_failing_dml_session(
        tmp_path, monkeypatch, cpu_fails=True,
    )
    image = np.zeros((64, 64, 3), dtype=np.uint8)

    with pytest.raises(UnicodeDecodeError):
        detector.predict([image], imgsz=64)

    # 只回退一次，不能无限重建会话。
    assert calls == ["DmlExecutionProvider", "CPUExecutionProvider"]
    assert detector.device == "cpu"
