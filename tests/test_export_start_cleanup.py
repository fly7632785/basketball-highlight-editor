import sqlite3
import threading
from pathlib import Path

import pytest

import engine.python.basketball_engine.service as module
from engine.python.basketball_engine.protocol import ProtocolError
from engine.python.basketball_engine.storage import ProjectStore
from tests.test_export_job_validation import setup_export, wait_job


@pytest.mark.parametrize('failure', ['identity', 'thread_construct', 'thread_start'])
def test_start_exception_never_leaves_queued_or_guard(tmp_path, monkeypatch, failure):
    service, store, source, payload = setup_export(tmp_path)
    with monkeypatch.context() as patch:
        if failure == 'identity':
            patch.setattr(service, '_project_identity', lambda *_: (_ for _ in ()).throw(ProtocolError('PROJECT_CHANGED', 'injected')))
        elif failure == 'thread_construct':
            patch.setattr(module.threading, 'Thread', lambda **_: (_ for _ in ()).throw(OSError('thread construction failed')))
        else:
            patch.setattr(module.threading.Thread, 'start', lambda *_: (_ for _ in ()).throw(RuntimeError('thread start failed')))
        with pytest.raises(ProtocolError):
            service.start_export(payload)
    assert store.list_jobs(store.project()['id'], states=('queued', 'running')) == []
    assert service._export_projects == {}
    assert service._job_threads == {}
    monkeypatch.setattr(service, '_execute_export', lambda *a, **k: {'export':{'id':'ok'}, 'files':[]})
    result = service.start_export(payload)
    assert wait_job(store, result['job']['id'])['state'] == 'completed'
    service.shutdown()


@pytest.mark.parametrize('mode', ['separate', 'merge_by_player', 'merge'])
@pytest.mark.parametrize('failure', [OSError, sqlite3.OperationalError])
def test_verify_failure_cleans_all_new_outputs_and_keeps_old(tmp_path, monkeypatch, mode, failure):
    service, store, source, payload = setup_export(tmp_path)
    payload['mode'] = mode
    old = tmp_path/'existing.mp4'
    old.write_bytes(b'old result')
    if mode == 'merge': payload['output_path'] = str(old)
    else: payload.pop('output_path')
    monkeypatch.setattr(service, 'inspect_video', lambda p: {})
    created = []
    def produced(output_dir, output_path=None):
        output_dir.mkdir(parents=True, exist_ok=True)
        path = output_path or output_dir/'new-result.mp4'
        path.write_bytes(b'new result')
        created.append(path)
        clip = output_dir/'new-clip.mp4'
        clip.write_bytes(b'clip')
        created.append(clip)
        return {'files':[str(path)], 'clip_files':[str(clip)], 'duration_ms':1000, 'processing_ms':1, 'merged_overlap_count':0}
    monkeypatch.setattr(module, 'export_goal_clips', lambda candidates, output_dir, mode, output_path, **kw: produced(output_dir, output_path))
    monkeypatch.setattr(service, '_export_merged_per_player', lambda store, candidates, output_dir, sources, **kw: produced(output_dir))
    original = ProjectStore.update_job
    def update(store, job_id, **kwargs):
        if kwargs.get('stage') == 'verify_source': raise failure('verify write failed')
        return original(store, job_id, **kwargs)
    monkeypatch.setattr(ProjectStore, 'update_job', update)
    result = service.start_export(payload)
    job = wait_job(store, result['job']['id'])
    assert job['state'] == 'failed'
    assert created and all(not path.exists() for path in created)
    assert old.read_bytes() == b'old result'
    assert store.list_exports(store.project()['id']) == []
    service.shutdown()


def test_commit_failure_after_thread_start_rolls_back_job(tmp_path, monkeypatch):
    from engine.python.basketball_engine.storage import _ClosingConnection
    service, store, source, payload = setup_export(tmp_path)
    original_start = threading.Thread.start
    original_exit = _ClosingConnection.__exit__
    started = False
    def start(thread):
        nonlocal started
        original_start(thread)
        started = True
    def exit_(connection, exc_type, exc, tb):
        nonlocal started
        if started and connection.in_transaction:
            started = False
            original_exit(connection, OSError, OSError('commit failed'), None)
            raise OSError('commit failed')
        return original_exit(connection, exc_type, exc, tb)
    with monkeypatch.context() as patch:
        patch.setattr(threading.Thread, 'start', start)
        patch.setattr(_ClosingConnection, '__exit__', exit_)
        with pytest.raises(ProtocolError) as error:
            service.start_export(payload)
        assert error.value.code == 'EXPORT_FAILED'
    assert store.list_jobs(store.project()['id'], states=('queued', 'running')) == []
    assert service._job_threads == {} and service._export_projects == {}
    monkeypatch.setattr(service, '_execute_export', lambda *a, **k: {'export':{'id':'ok'}, 'files':[]})
    assert wait_job(store, service.start_export(payload)['job']['id'])['state'] == 'completed'
    service.shutdown()
