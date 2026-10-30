import io
import json
import queue
import shutil
import threading
import time
from pathlib import Path

import pytest

from engine.python.basketball_engine import server
from engine.python.basketball_engine.protocol import ProtocolError
from engine.python.basketball_engine.request_control import fingerprint, set_cancel_event
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore


class Input:
    def __init__(self): self.items = queue.Queue()
    def __iter__(self):
        while (item := self.items.get()) is not None:
            yield json.dumps(item) + '\n'
    def send(self, response_id, command, **payload):
        self.items.put({'protocol_version': '1.0', 'type': 'request',
                        'request_id': response_id, 'command': command, 'payload': payload})


class Output(io.StringIO):
    def __init__(self):
        super().__init__()
        self.items = queue.Queue()
    def write(self, text):
        self.items.put(json.loads(text))
        return len(text)
    def flush(self): pass
    def next(self, timeout=3): return self.items.get(timeout=timeout)


@pytest.fixture
def running(monkeypatch, tmp_path):
    service = EngineService()
    for name in ('a', 'b', 'c'):
        service.create_project({'root_path': str(tmp_path / name), 'name': name})
    video = tmp_path / 'video.mp4'
    video.write_bytes(b'small sample')
    def inspect(payload):
        path = Path(payload['video_path']).resolve()
        stat = path.stat()
        return {'source_path': str(path), 'source_size_bytes': stat.st_size,
                'source_mtime_ns': stat.st_mtime_ns, 'width': 64, 'height': 64,
                'duration_ms': 1000}
    monkeypatch.setattr(service, 'inspect_video', inspect)
    entered, release = threading.Event(), threading.Event()
    def slow(path):
        entered.set()
        assert release.wait(5)
        return fingerprint(path)
    monkeypatch.setattr(service, '_source_fingerprint', slow)
    input_, output = Input(), Output()
    monkeypatch.setattr(server, 'EngineService', lambda: service)
    monkeypatch.setattr(server, 'environment_summary', lambda: 'test')
    monkeypatch.setattr(server.sys, 'stdin', input_)
    monkeypatch.setattr(server.sys, 'stdout', output)
    thread = threading.Thread(target=server.main)
    thread.start()
    yield service, input_, output, entered, release, video
    release.set()
    input_.items.put(None)
    thread.join(8)
    assert not thread.is_alive()


def test_slow_link_leaves_loop_responsive_and_bounded(running, tmp_path):
    service, input_, output, entered, release, video = running
    input_.send('first', 'link_video', project_root=str(tmp_path/'a'), video_path=str(video))
    assert entered.wait(3)
    input_.send('delete', 'delete_project', project_root=str(tmp_path/'a'))
    assert output.next()['error']['code'] == 'PROJECT_BUSY'
    input_.send('save', 'save_roi', project_root=str(tmp_path/'a'))
    assert output.next()['error']['code'] == 'PROJECT_BUSY'
    input_.send('second', 'link_video', project_root=str(tmp_path/'b'), video_path=str(video))
    input_.send('third', 'link_video', project_root=str(tmp_path/'c'), video_path=str(video))
    assert output.next()['error']['code'] == 'PROJECT_BUSY'
    input_.send('hello', 'hello')
    assert output.next()['request_id'] == 'hello'
    input_.send('job', 'get_job', project_root=str(tmp_path/'a'), job_id='missing')
    assert output.next()['request_id'] == 'job'
    input_.send('cancel', 'cancel_request', request_id='first')
    assert output.next()['payload']['cancel_requested'] is True
    release.set()
    responses = {r['request_id']: r for r in [output.next(), output.next()]}
    assert responses['first']['error']['code'] == 'REQUEST_CANCELLED'
    assert responses['second']['ok'] is True
    assert service._require_store({'project_root': str(tmp_path/'a')}).list_videos() == []


def test_external_delete_recreate_does_not_receive_late_link(running, tmp_path):
    service, input_, output, entered, release, video = running
    root = tmp_path/'a'
    input_.send('first', 'link_video', project_root=str(root), video_path=str(video))
    assert entered.wait(3)
    shutil.rmtree(root)
    replacement = EngineService()
    replacement.create_project({'root_path': str(root), 'name': 'replacement'})
    release.set()
    response = output.next()
    assert response['error']['code'] == 'PROJECT_CHANGED'
    assert replacement._require_store({'project_root': str(root)}).list_videos() == []


def test_hash_cancelled_before_read(tmp_path):
    source = tmp_path/'video'
    source.write_bytes(b'abc')
    event = threading.Event()
    event.set()
    set_cancel_event(event)
    try:
        with pytest.raises(ProtocolError, match='请求已取消') as error:
            fingerprint(source)
        assert error.value.code == 'REQUEST_CANCELLED'
    finally:
        set_cancel_event(None)

@pytest.mark.parametrize('command', ['relink_video', 'suggest_roi', 'extract_preview'])
def test_slow_validation_commands_do_not_block_other_requests(running, tmp_path, monkeypatch, command):
    service, input_, output, entered, release, source = running
    store = service._require_store({'project_root': str(tmp_path/'a')})
    video = store.link_video(service.inspect_video({'video_path': str(source)}))
    if command in {'suggest_roi', 'extract_preview'}:
        monkeypatch.setattr(EngineService, '_source_fingerprint', staticmethod(service._source_fingerprint))
    input_.send('slow', command, project_root=str(tmp_path/'a'), video_id=video['id'], video_path=str(source), model_path=str(tmp_path/'missing.pt'))
    assert entered.wait(3)
    input_.send('hello', 'hello')
    assert output.next()['request_id'] == 'hello'
    input_.send('same', 'relink_video', project_root=str(tmp_path/'a'), video_id=video['id'], video_path=str(source))
    assert output.next()['error']['code'] == 'PROJECT_BUSY'
    release.set()
    result = output.next()
    assert result['request_id'] == 'slow'
    if command == 'relink_video':
        assert result['ok']
    else:
        assert result['error']['code'] == ('MODEL_LOAD_FAILED' if command == 'suggest_roi' else 'VIDEO_OPEN_FAILED')


def test_external_recreate_does_not_receive_late_relink(running, tmp_path):
    service, input_, output, entered, release, source = running
    root = tmp_path/'a'
    store = service._require_store({'project_root': str(root)})
    video = store.link_video(service.inspect_video({'video_path': str(source)}))
    input_.send('relink', 'relink_video', project_root=str(root), video_id=video['id'], video_path=str(source))
    assert entered.wait(3)
    shutil.rmtree(root)
    replacement = EngineService()
    replacement.create_project({'root_path': str(root), 'name': 'new'})
    release.set()
    assert output.next()['error']['code'] == 'PROJECT_CHANGED'
    assert replacement._require_store({'project_root': str(root)}).list_videos() == []


def test_fingerprint_checks_cancellation_between_chunks(tmp_path, monkeypatch):
    source = tmp_path/'video'
    source.write_bytes(b'x' * (2 * 1024 * 1024))
    event = threading.Event()
    original_open = Path.open
    class Wrapper:
        def __init__(self, stream): self.stream = stream
        def __enter__(self): return self
        def __exit__(self, *args): self.stream.close()
        def fileno(self): return self.stream.fileno()
        def read(self, size):
            data = self.stream.read(size)
            event.set()
            return data
    monkeypatch.setattr(Path, 'open', lambda path, *args, **kwargs: Wrapper(original_open(path, *args, **kwargs)))
    set_cancel_event(event)
    try:
        with pytest.raises(ProtocolError) as error:
            fingerprint(source)
        assert error.value.code == 'REQUEST_CANCELLED'
    finally:
        set_cancel_event(None)


def test_cancel_after_commit_start_is_reported_too_late(running, tmp_path, monkeypatch):
    service, input_, output, entered, release, source = running
    committed = threading.Event()
    finish = threading.Event()
    original = ProjectStore.link_video
    def gated(store, metadata):
        committed.set()
        assert finish.wait(5)
        return original(store, metadata)
    monkeypatch.setattr(ProjectStore, 'link_video', gated)
    input_.send('first', 'link_video', project_root=str(tmp_path/'a'), video_path=str(source))
    assert entered.wait(3)
    release.set()
    assert committed.wait(3)
    input_.send('cancel', 'cancel_request', request_id='first')
    assert output.next()['payload']['cancel_requested'] is False
    finish.set()
    assert output.next()['ok'] is True


def test_accepted_cancel_wins_over_late_io_failure(running, tmp_path, monkeypatch):
    service, input_, output, entered, release, source = running
    def failing(path):
        entered.set()
        assert release.wait(5)
        raise OSError('read failed')
    monkeypatch.setattr(service, '_source_fingerprint', failing)
    input_.send('first', 'link_video', project_root=str(tmp_path/'a'), video_path=str(source))
    assert entered.wait(3)
    input_.send('cancel', 'cancel_request', request_id='first')
    assert output.next()['payload']['cancel_requested'] is True
    release.set()
    assert output.next()['error']['code'] == 'REQUEST_CANCELLED'
    assert service._require_store({'project_root': str(tmp_path/'a')}).list_videos() == []


def test_open_legacy_orientation_fingerprint_runs_off_main_loop(running, tmp_path):
    service, input_, output, entered, release, source = running
    root = tmp_path/'a'
    store = service._require_store({'project_root': str(root)})
    video = store.link_video(service.inspect_video({'video_path': str(source)}))
    with store.connect() as connection:
        connection.execute('UPDATE videos SET source_fingerprint = NULL WHERE id = ?', (video['id'],))
    input_.send('open', 'open_project', project_root=str(root))
    assert entered.wait(3)
    input_.send('hello', 'hello')
    assert output.next()['request_id'] == 'hello'
    release.set()
    assert output.next()['ok'] is True


def test_link_retry_deduplicates_same_source(running, tmp_path):
    service, input_, output, entered, release, source = running
    root = tmp_path/'a'
    input_.send('first', 'link_video', project_root=str(root), video_path=str(source))
    assert entered.wait(3)
    release.set()
    first = output.next()
    assert first['ok']
    for attempt in range(20):
        input_.send(f'again-{attempt}', 'link_video', project_root=str(root), video_path=str(source))
        second = output.next()
        if second['ok']:
            break
        assert second['error']['code'] == 'PROJECT_BUSY'
        time.sleep(.01)
    assert second['ok']
    assert first['payload']['video']['id'] == second['payload']['video']['id']
    assert len(service._require_store({'project_root': str(root)}).list_videos()) == 1
