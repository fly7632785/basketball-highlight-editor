import os
import threading
import time
from pathlib import Path

import pytest

from engine.python.basketball_engine.protocol import ProtocolError
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore


def setup_export(tmp_path, fingerprint=True):
    service = EngineService()
    root, source = tmp_path/'project', tmp_path/'video.mp4'
    service.create_project({'name': 'test', 'root_path': str(root)})
    source.write_bytes(b'video content')
    stat = source.stat()
    store = ProjectStore(root)
    metadata = {'source_path': str(source), 'source_size_bytes': stat.st_size,
                'source_mtime_ns': stat.st_mtime_ns, 'duration_ms': 2000,
                'width': 64, 'height': 64, 'video_codec': 'h264'}
    video = store.link_video(metadata)
    if not fingerprint:
        with store.connect() as connection:
            connection.execute('UPDATE videos SET source_fingerprint=NULL WHERE id=?', (video['id'],))
    store.replace_candidates(video['id'], [{'id':'c1', 'video_id':video['id'], 'event_time_ms':500,
        'default_start_ms':0, 'default_end_ms':1000, 'review_start_ms':0, 'review_end_ms':1000,
        'detector_version':'test', 'score':.8, 'confidence':'review', 'evidence_json':'{}'}])
    payload = {'project_root': str(root), 'video_id': video['id'], 'mode': 'merge',
               'output_dir': str(tmp_path/'out'), 'output_path': str(tmp_path/'result.mp4')}
    return service, store, source, payload


def wait_job(store, job_id, state=None):
    deadline = time.monotonic()+4
    while time.monotonic() < deadline:
        job = store.get_job(job_id)
        if job and (state is None and job['state'] in {'completed','failed','cancelled'} or job['stage'] == state):
            return job
        time.sleep(.01)
    raise AssertionError(f'job did not reach {state}: {store.get_job(job_id)}')


def test_start_returns_before_validation_and_cancel_keeps_worker_registered(tmp_path, monkeypatch):
    service, store, source, payload = setup_export(tmp_path)
    entered, release = threading.Event(), threading.Event()
    original = EngineService._source_fingerprint
    def slow(path):
        entered.set()
        assert release.wait(4)
        return original(path)
    monkeypatch.setattr(EngineService, '_source_fingerprint', staticmethod(slow))
    started = service.start_export(payload)
    assert started['job']['id']
    assert entered.wait(2)
    job_id = started['job']['id']
    assert service.get_job({'project_root':str(store.root), 'job_id':job_id})['job']['stage'] == 'validate_source'
    service.create_project({'root_path':str(tmp_path/'other'), 'name':'other'})
    with pytest.raises(ProtocolError) as busy:
        service.start_export(payload)
    assert busy.value.code == 'JOB_ALREADY_RUNNING'
    result = service.cancel_job({'project_root':str(store.root), 'job_id':job_id})
    assert result['job']['stage'] == 'cancelling'
    assert job_id in service._job_threads
    release.set()
    assert wait_job(store, job_id)['state'] == 'cancelled'
    assert store.list_exports(store.project()['id']) == []
    service.shutdown()


@pytest.mark.parametrize('cancel', [False, True])
def test_verify_interruption_keeps_old_output_and_no_export_record(tmp_path, monkeypatch, cancel):
    import engine.python.basketball_engine.service as module
    service, store, source, payload = setup_export(tmp_path)
    target = Path(payload['output_path'])
    target.write_bytes(b'old product')
    entered, release = threading.Event(), threading.Event()
    original = EngineService._source_fingerprint
    calls = 0
    def gate(path):
        nonlocal calls
        calls += 1
        if calls == 2:
            entered.set()
            assert release.wait(4)
        return original(path)
    monkeypatch.setattr(EngineService, '_source_fingerprint', staticmethod(gate))
    monkeypatch.setattr(service, 'inspect_video', lambda p: {})
    def fake_export(candidates, output_dir, mode, output_path, **kwargs):
        output_dir.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(b'new product')
        return {'files':[str(output_path)], 'clip_files':[], 'duration_ms':1000, 'processing_ms':1, 'merged_overlap_count':0}
    monkeypatch.setattr(module, 'export_goal_clips', fake_export)
    started = service.start_export(payload)
    assert entered.wait(2)
    job_id = started['job']['id']
    assert service.get_job({'project_root':str(store.root), 'job_id':job_id})['job']['stage'] == 'verify_source'
    if cancel:
        assert service.cancel_job({'project_root':str(store.root), 'job_id':job_id})['job']['stage'] == 'cancelling'
    else:
        stat = source.stat()
        source.write_bytes(b'other content')
        os.utime(source, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    release.set()
    job = wait_job(store, job_id)
    assert job['state'] == ('cancelled' if cancel else 'failed')
    assert job['error_code'] == ('JOB_CANCELLED' if cancel else 'VIDEO_SOURCE_CHANGED')
    assert target.read_bytes() == b'old product'
    assert store.list_exports(store.project()['id']) == []
    assert not list(target.parent.glob('.result.stage_*.mp4'))
    service.shutdown()


def test_project_recreated_while_hashing_never_writes_into_replacement(tmp_path, monkeypatch):
    import shutil
    service, store, source, payload = setup_export(tmp_path)
    root = store.root
    entered, release = threading.Event(), threading.Event()
    original = EngineService._source_fingerprint
    def gate(path):
        entered.set()
        assert release.wait(4)
        return original(path)
    monkeypatch.setattr(EngineService, '_source_fingerprint', staticmethod(gate))
    started = service.start_export(payload)
    assert entered.wait(2)
    with pytest.raises(ProtocolError) as busy:
        service.delete_project({'project_root':str(root)})
    assert busy.value.code == 'PROJECT_BUSY'
    shutil.rmtree(root)
    replacement = EngineService()
    replacement.create_project({'root_path':str(root), 'name':'replacement'})
    release.set()
    deadline = time.monotonic()+3
    while started['job']['id'] in service._job_threads and time.monotonic() < deadline:
        time.sleep(.01)
    assert started['job']['id'] not in service._job_threads
    fresh = ProjectStore(root)
    assert fresh.list_exports(fresh.project()['id']) == []
    assert not Path(payload['output_path']).exists()
    service.shutdown()


def test_legacy_source_without_fingerprint_records_warning(tmp_path, monkeypatch):
    import engine.python.basketball_engine.service as module
    service, store, source, payload = setup_export(tmp_path, fingerprint=False)
    monkeypatch.setattr(service, 'inspect_video', lambda p: {})
    def fake_export(candidates, output_dir, mode, output_path, **kwargs):
        output_dir.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(b'finished')
        return {'files':[str(output_path)], 'clip_files':[], 'duration_ms':1000, 'processing_ms':1, 'merged_overlap_count':0}
    monkeypatch.setattr(module, 'export_goal_clips', fake_export)
    started = service.start_export(payload)
    job = wait_job(store, started['job']['id'])
    assert job['state'] == 'completed'
    exports = store.list_exports(store.project()['id'])
    assert exports[0]['metadata']['source_unverified'] is True
    service.shutdown()


def test_history_write_failure_restores_previous_output_and_no_record(tmp_path, monkeypatch):
    import engine.python.basketball_engine.service as module
    service, store, source, payload = setup_export(tmp_path)
    target = Path(payload['output_path'])
    target.write_bytes(b'old product')
    monkeypatch.setattr(service, 'inspect_video', lambda p: {})
    def fake_export(candidates, output_dir, mode, output_path, **kwargs):
        output_dir.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(b'new product')
        return {'files':[str(output_path)], 'clip_files':[], 'duration_ms':1000, 'processing_ms':1, 'merged_overlap_count':0}
    monkeypatch.setattr(module, 'export_goal_clips', fake_export)
    monkeypatch.setattr(ProjectStore, 'complete_export_job', lambda *a, **k: (_ for _ in ()).throw(OSError('disk error')))
    job = service.start_export(payload)['job']
    finished = wait_job(store, job['id'])
    assert finished['state'] == 'failed'
    assert target.read_bytes() == b'old product'
    assert store.list_exports(store.project()['id']) == []
    service.shutdown()


def test_export_record_rolls_back_when_job_cannot_complete(tmp_path):
    service, store, source, payload = setup_export(tmp_path)
    project = store.project()
    job = store.create_job(project['id'], payload['video_id'], 'export', {})
    store.update_job(job['id'], state='cancelled')
    values = {'project_id':project['id'], 'video_id':payload['video_id'], 'output_path':'/tmp/result.mp4',
              'mode':'merge', 'metadata':{'files':['/tmp/result.mp4']}}
    with pytest.raises(ValueError, match='EXPORT_JOB_NOT_ACTIVE'):
        store.complete_export_job(values, job['id'], {})
    assert store.list_exports(project['id']) == []
    service.shutdown()


def test_server_remains_responsive_during_export_validation(tmp_path, monkeypatch):
    from engine.python.basketball_engine import server
    from tests.test_request_pool import Input, Output
    service, store, source, payload = setup_export(tmp_path)
    entered, release = threading.Event(), threading.Event()
    original = EngineService._source_fingerprint
    def gate(path):
        entered.set()
        assert release.wait(4)
        return original(path)
    monkeypatch.setattr(EngineService, '_source_fingerprint', staticmethod(gate))
    input_, output = Input(), Output()
    monkeypatch.setattr(server, 'EngineService', lambda: service)
    monkeypatch.setattr(server, 'environment_summary', lambda: 'test')
    monkeypatch.setattr(server.sys, 'stdin', input_)
    monkeypatch.setattr(server.sys, 'stdout', output)
    thread = threading.Thread(target=server.main)
    thread.start()
    try:
        input_.send('start', 'start_export', **payload)
        started = output.next()
        assert started['ok'] and started['request_id'] == 'start'
        assert entered.wait(2)
        job_id = started['payload']['job']['id']
        input_.send('job', 'get_job', project_root=str(store.root), job_id=job_id)
        assert output.next()['payload']['job']['stage'] == 'validate_source'
        input_.send('hello', 'hello')
        assert output.next()['request_id'] == 'hello'
        input_.send('cancel', 'cancel_job', project_root=str(store.root), job_id=job_id)
        assert output.next()['payload']['job']['stage'] == 'cancelling'
        release.set()
        assert wait_job(store, job_id)['state'] == 'cancelled'
    finally:
        release.set()
        input_.items.put(None)
        thread.join(6)
        assert not thread.is_alive()
