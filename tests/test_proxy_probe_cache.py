"""extract_preview 的代理探测缓存：同一代理文件批量取帧只 ffprobe 一次。"""
from engine.python.basketball_engine.service import EngineService


def test_same_proxy_probed_once_until_file_changes(tmp_path, monkeypatch):
    service = EngineService()
    proxy = tmp_path / "proxy.mp4"
    proxy.write_bytes(b"proxy")
    calls = []

    def inspect(payload):
        calls.append(payload["video_path"])
        return {"width": 960, "height": 540, "duration_ms": 5000, "rotation": 0}

    monkeypatch.setattr(service, "inspect_video", inspect)
    first = service._cached_proxy_probe(proxy)
    second = service._cached_proxy_probe(proxy)
    assert first == second
    assert calls == [str(proxy)]
    # 代理被重写（大小/mtime 变化）后必须重新探测
    proxy.write_bytes(b"proxy rewritten and longer")
    third = service._cached_proxy_probe(proxy)
    assert calls == [str(proxy), str(proxy)]
    assert third["duration_ms"] == 5000


def test_missing_proxy_still_probed_each_time(tmp_path, monkeypatch):
    service = EngineService()
    proxy = tmp_path / "gone.mp4"
    calls = []

    def inspect(payload):
        calls.append(payload["video_path"])
        return {"width": 64, "height": 48}

    monkeypatch.setattr(service, "inspect_video", inspect)
    assert service._cached_proxy_probe(proxy)["width"] == 64
    assert service._cached_proxy_probe(proxy)["width"] == 64
    assert len(calls) == 2
