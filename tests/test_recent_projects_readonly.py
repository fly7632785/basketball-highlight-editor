"""Recent-list IO must never enter the writable/migrating store lifecycle."""
import hashlib
import sqlite3
from pathlib import Path

import pytest

from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore


@pytest.fixture
def legacy(tmp_path):
    root = tmp_path / 'legacy # 球场'
    root.mkdir()
    db = root / 'project.db'
    schema = Path(__file__).resolve().parents[1] / 'docs/architecture/SQLITE_SCHEMA_V1.sql'
    with sqlite3.connect(db) as con:
        con.executescript(schema.read_text())
        con.execute("INSERT INTO projects(id,name,root_path,created_at,updated_at) VALUES('p','Legacy',?,'a','a')", (str(root),))
        con.execute("INSERT INTO videos(id,project_id,source_path,source_size_bytes,source_mtime_ns,duration_ms,created_at,updated_at) VALUES('v','p',?,1,1,600000,'a','a')", (str(tmp_path / 'missing.mp4'),))
        con.execute("INSERT INTO players(id,project_id,name,created_at,updated_at) VALUES('tag','p','Synthetic','a','a')")
        for i, status in enumerate(['goal', 'excluded', 'pending']):
            con.execute("INSERT INTO candidates(id,video_id,event_time_ms,default_start_ms,default_end_ms,review_start_ms,review_end_ms,detector_version,created_at,updated_at) VALUES(?,'v',?,0,2000,0,2000,'test','a','a')", (f'c{i}', i * 1000))
            con.execute("INSERT INTO candidate_reviews(candidate_id,status,reason,player_id,updated_at) VALUES(?,?,?,?, 'a')", (f'c{i}', status, 'made' if i == 0 else 'rim_out' if i == 1 else None, 'tag' if i == 0 else None))
        # Older than several non-tier fields too; listing must not add them.
        con.execute('ALTER TABLE videos DROP COLUMN sort_index')
        con.execute('ALTER TABLE videos DROP COLUMN rotation')
        con.execute('ALTER TABLE projects DROP COLUMN workflow_draft_json')
        con.execute('ALTER TABLE candidate_reviews DROP COLUMN review_duration_ms')
    return root


def inventory(root):
    return {str(p.relative_to(root)): (p.stat().st_mtime_ns, hashlib.sha256(p.read_bytes()).hexdigest())
            for p in root.rglob('*') if p.is_file()}


def test_listing_legacy_preserves_mtime_sha256_and_creates_no_backup(legacy, monkeypatch):
    before = inventory(legacy)
    def forbidden(*args, **kwargs):
        pytest.fail('recent-project listing entered a writable ProjectStore method')
    for method in ['connect', 'initialize', 'context', 'list_candidates', '_backup_before_tiers_migration', '_ensure_schema_compatibility']:
        monkeypatch.setattr(ProjectStore, method, forbidden)
    service = EngineService()
    for _ in range(2):
        result = service.handle('list_recent_projects', {'roots': [str(legacy.parent)]})
        item, = result['projects']
        assert item['project']['name'] == 'Legacy'
        assert item['project']['tier_rule_version'] == 'r2-v1'
        assert item['video']['duration_ms'] == 600000
        assert item['video']['rotation'] == 0
        assert item['video']['source_status'] == 'missing'
        assert item['statistics']['candidate_count'] == 3
        assert item['statistics']['included_count'] == 2
        assert item['statistics']['goal_count'] == 1
        assert item['statistics']['export_count'] == 0
        # Explicit hard gates: nanosecond mtime and SHA256, not just row counts.
        assert inventory(legacy)['project.db'][0] == before['project.db'][0]
        assert inventory(legacy)['project.db'][1] == before['project.db'][1]
        assert inventory(legacy) == before
        assert not list(legacy.glob('*.bak'))
        assert not list(legacy.glob('.pre-tiers-*'))
    assert service.stores == {}


def test_only_open_migrates_and_backup_exists_before_first_schema_change(legacy, monkeypatch):
    db = legacy / 'project.db'
    before = inventory(legacy)
    with sqlite3.connect(db) as con:
        old_dump = list(con.iterdump())
    service = EngineService()
    service.handle('list_recent_projects', {'roots': [str(legacy)]})
    assert inventory(legacy) == before
    assert not list(legacy.glob('*.bak'))
    ensure = ProjectStore._ensure_schema_compatibility
    checked = []
    def check_backup_then_migrate(connection):
        backup = legacy / 'project.db.pre-tiers-v1.bak'
        assert backup.is_file()  # Must predate entry to the schema writer.
        with sqlite3.connect(backup.as_uri() + '?mode=ro&immutable=1', uri=True) as saved:
            assert list(saved.iterdump()) == old_dump
            assert saved.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        if not checked:
            assert 'tier_rule_version' not in {r[1] for r in connection.execute('PRAGMA table_info(projects)')}
            assert not connection.execute("SELECT 1 FROM sqlite_master WHERE name='candidate_tags'").fetchone()
        checked.append(True)
        ensure(connection)
    monkeypatch.setattr(ProjectStore, '_ensure_schema_compatibility', staticmethod(check_backup_then_migrate))
    context = service.handle('open_project', {'project_root': str(legacy)})
    assert checked
    assert context['statistics']['candidate_count'] == 3
    with sqlite3.connect(db) as con:
        assert con.execute("SELECT name FROM schema_migrations WHERE name='candidate_tags_v1'").fetchone()
        assert con.execute('SELECT candidate_id,player_id FROM candidate_tags').fetchall() == [('c0', 'tag')]
        assert con.execute('SELECT status,reason FROM candidate_reviews ORDER BY candidate_id').fetchall() == [('goal','made'),('excluded','rim_out'),('pending',None)]
    after = inventory(legacy)
    assert after['project.db'][0] != before['project.db'][0]
    assert after['project.db'][1] != before['project.db'][1]


def test_recent_metadata_connection_is_sqlite_readonly(legacy, monkeypatch):
    connect = sqlite3.connect
    def readonly(*args, **kwargs):
        assert 'mode=ro&immutable=1' in args[0]
        con = connect(*args, **kwargs)
        with pytest.raises(sqlite3.OperationalError, match='readonly'):
            con.execute("UPDATE projects SET name='should not write'")
        return con
    monkeypatch.setattr(sqlite3, 'connect', readonly)
    ProjectStore(legacy).recent_context()


def test_listing_live_wal_leaves_all_sidecars_unchanged(legacy):
    # Listing reads the last checkpoint only; opening retains WAL-aware migration.
    con = sqlite3.connect(legacy / 'project.db')
    try:
        con.execute('PRAGMA journal_mode=WAL')
        con.execute("UPDATE projects SET name='Committed in WAL'")
        con.commit()
        before = inventory(legacy)
        item, = EngineService().handle('list_recent_projects', {'roots': [str(legacy)]})['projects']
        assert item['project']['name'] == 'Legacy'
        assert inventory(legacy) == before
        assert not list(legacy.glob('*.bak'))
    finally:
        con.close()
