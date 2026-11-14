"""Request cancellation uses real server admission and a real slow subprocess."""
import json
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from engine.python.basketball_engine import server
from engine.python.basketball_engine import service as service_module
from engine.python.basketball_engine.request_control import set_cancel_event


class Requests:
    def __init__(self):
        self.items = queue.Queue()

    def __iter__(self):
        while (value := self.items.get()) is not None:
            yield json.dumps(value) + '\n'

    def send(self, identifier, command, **payload):
        self.items.put({'protocol_version': '1.0', 'type': 'request',
                        'request_id': identifier, 'command': command, 'payload': payload})


class Responses:
    def __init__(self):
        self.items = queue.Queue()
        self.pending = {}

    def write(self, value):
        self.items.put(json.loads(value))
        return len(value)

    def flush(self):
        pass

    def response(self, identifier, timeout=5):
        deadline = time.monotonic() + timeout
        while identifier not in self.pending:
            item = self.items.get(timeout=max(0, deadline - time.monotonic()))
            self.pending[item['request_id']] = item
        return self.pending.pop(identifier)


def preview_project(tmp_path, monkeypatch):
    service = service_module.EngineService()
    root = tmp_path / 'project'
    service.create_project({'root_path': str(root), 'name': 'cancel probe'})
    source = tmp_path / 'source.mp4'
    source.write_bytes(b'probe')
    stat = source.stat()
    store = service._require_store({'project_root': str(root)})
    video = store.link_video({'source_path': str(source), 'source_size_bytes': stat.st_size,
                             'source_mtime_ns': stat.st_mtime_ns, 'width': 640,
                             'height': 480, 'duration_ms': 5000})
    monkeypatch.setattr(service, '_validated_source', lambda *a, **k: source)
    monkeypatch.setattr(service, '_latest_proxy_video', lambda *a: None)
    return service, root, source, store, video


def test_cancel_preview_releases_project_promptly_and_reaps_child(tmp_path, monkeypatch):
    service, root, source, store, video = preview_project(tmp_path, monkeypatch)
    marker = tmp_path / 'child-started'
    real_popen = subprocess.Popen
    children = []

    def slow_frame(command, **kwargs):
        if '-frames:v' not in command:
            return real_popen(command, **kwargs)
        code = "from pathlib import Path; import time,sys; Path(sys.argv[1]).touch(); time.sleep(2); Path(sys.argv[2]).write_bytes(b'frame')"
        if sys.platform != 'win32':
            kwargs.setdefault('start_new_session', True)
        child = real_popen([sys.executable, '-c', code, str(marker), command[-1]], **kwargs)
        children.append(child)
        return child

    monkeypatch.setattr(subprocess, 'Popen', slow_frame)
    requests, responses = Requests(), Responses()
    monkeypatch.setattr(server, 'EngineService', lambda: service)
    monkeypatch.setattr(server, 'environment_summary', lambda: 'cancel probe')
    monkeypatch.setattr(server.sys, 'stdin', requests)
    monkeypatch.setattr(server.sys, 'stdout', responses)
    thread = threading.Thread(target=server.main)
    thread.start()
    preview_finished = False
    try:
        requests.send('preview', 'extract_preview', project_root=str(root), video_id=video['id'])
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        assert marker.exists()
        requests.send('cancel', 'cancel_request', request_id='preview')
        assert responses.response('cancel')['payload']['cancel_requested'] is True
        time.sleep(.25)
        requests.send('next', 'save_roi', project_root=str(root), video_id=video['id'],
                      x1=10, y1=20, x2=200, y2=180)
        next_response = responses.response('next')
        assert next_response.get('error', {}).get('code') != 'PROJECT_BUSY'
        assert next_response['ok'] is True, next_response
        result = responses.response('preview', timeout=1)
        preview_finished = True
        assert result['error']['code'] == 'REQUEST_CANCELLED'
        assert len(children) == 1 and children[0].poll() is not None
        assert not service._preview_path(store, video, 1000).exists()
        assert not list((root / 'artifacts' / 'previews').glob('*.tmp*'))
    finally:
        for child in children:
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
        # The request worker owns communicate()/its pipe handles. Wait for its
        # response before server shutdown, including on the expected red probe.
        if not preview_finished:
            responses.response('preview')
        requests.items.put(None)
        thread.join(5)
        assert not thread.is_alive()


def test_cancelled_proxy_failure_does_not_start_original_retry(tmp_path, monkeypatch):
    service, root, source, store, video = preview_project(tmp_path, monkeypatch)
    proxy = tmp_path / 'proxy.mp4'
    proxy.write_bytes(b'proxy')
    monkeypatch.setattr(service, '_latest_proxy_video', lambda *a: (proxy, 0, 5000))
    monkeypatch.setattr(service, 'inspect_video', lambda *a: {
        'width': 64, 'height': 48, 'duration_ms': 5000, 'rotation': 0})
    event = threading.Event()
    calls = []

    def fail(command, **kwargs):
        calls.append(command)
        Path(command[-1]).write_bytes(b'partial')
        event.set()
        raise OSError('proxy disconnected')

    monkeypatch.setattr(subprocess, 'Popen', fail)
    set_cancel_event(event)
    try:
        with pytest.raises(service_module.ProtocolError) as error:
            service.extract_preview({'project_root': str(root), 'video_id': video['id']})
        assert error.value.code == 'REQUEST_CANCELLED'
        assert len(calls) == 1
        assert not list((root / 'artifacts' / 'previews').glob('*.tmp*'))
    finally:
        set_cancel_event(None)


def test_preview_deadline_terminates_and_reaps_slow_child(tmp_path, monkeypatch):
    service, root, source, store, video = preview_project(tmp_path, monkeypatch)
    real_popen = subprocess.Popen
    children = []

    def slow_frame(command, **kwargs):
        if '-frames:v' not in command:
            return real_popen(command, **kwargs)
        child = real_popen([sys.executable, '-c', 'import time; time.sleep(20)'], **kwargs)
        children.append(child)
        Path(command[-1]).write_bytes(b'partial')
        return child

    monkeypatch.setattr(subprocess, 'Popen', slow_frame)
    clock = iter([0, 61])
    monkeypatch.setattr(service_module, 'time', SimpleNamespace(monotonic=lambda: next(clock)))
    with pytest.raises(service_module.ProtocolError) as error:
        service.extract_preview({'project_root': str(root), 'video_id': video['id']})
    assert error.value.code == 'VIDEO_OPEN_FAILED'
    assert len(children) == 1 and children[0].poll() is not None
    assert not list((root / 'artifacts' / 'previews').glob('*.tmp*'))
