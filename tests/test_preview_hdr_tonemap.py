# L127 预览/封面 HDR 色调映射测试（不依赖真实 HDR 片）
from pathlib import Path

from engine.python.basketball_engine import service
from engine.python.basketball_engine.adapters import hdr


HDR_INFO = {'pix_fmt': 'yuv420p10le', 'color_transfer': 'smpte2084',
            'color_primaries': 'bt2020', 'color_space': 'bt2020nc', 'side_data_list': []}
SDR_INFO = {'pix_fmt': 'yuv420p', 'color_transfer': 'bt709',
            'color_primaries': 'bt709', 'color_space': 'bt709', 'side_data_list': []}


def _gate(monkeypatch, info, tonemap=True):
    monkeypatch.setattr(service.EngineService, 'inspect_video',
                        lambda self, payload: dict(info))
    # color_plan 在 hdr 模块内部查滤镜可用性，patch 模块级函数
    monkeypatch.setattr(hdr, 'hdr_filter_available', lambda: tonemap)
    monkeypatch.setattr(service, 'hdr_filter_available', lambda: tonemap)


def test_hdr_source_preview_vf_includes_tonemap(monkeypatch):
    _gate(monkeypatch, HDR_INFO)
    vf = service.EngineService()._preview_frame_vf(Path('a.mp4'))
    assert vf.startswith(hdr.TONEMAP_FILTER)
    assert vf.endswith('scale=640:-2')
    # 映射在缩放前，输出仍是 640 宽
    assert 'tonemap=hable' in vf


def test_sdr_source_preview_vf_unchanged(monkeypatch):
    _gate(monkeypatch, SDR_INFO)
    vf = service.EngineService()._preview_frame_vf(Path('a.mp4'))
    assert vf == 'scale=640:-2'


def test_hdr_without_filters_falls_back(monkeypatch):
    # 本机 ffmpeg 无 zscale 的情形：不加映射滤镜，保持旧行为
    _gate(monkeypatch, HDR_INFO, tonemap=False)
    vf = service.EngineService()._preview_frame_vf(Path('a.mp4'))
    assert vf == 'scale=640:-2'


def test_probe_failure_falls_back(monkeypatch):
    def boom(self, payload):
        raise service.ProtocolError('VIDEO_OPEN_FAILED', 'x')
    monkeypatch.setattr(service.EngineService, 'inspect_video', boom)
    vf = service.EngineService()._preview_frame_vf(Path('a.mp4'))
    assert vf == 'scale=640:-2'
