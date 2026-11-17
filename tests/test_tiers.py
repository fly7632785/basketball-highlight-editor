import json
import math
import sqlite3
from concurrent.futures import ThreadPoolExecutor

import pytest

from engine.python.basketball_engine.tiers import classify, filter_candidates
from engine.python.basketball_engine.storage import ProjectStore
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.protocol import ProtocolError


def evidence(**changes):
    base = dict(analysis_source='refined', rim_check=dict(status='made',rebound=False,net_motion=3),
                tier_calibration=dict(samples=8,median=10))
    base.update(changes)
    return base


@pytest.mark.parametrize('change,mode,tier', [
    ({},'standard','must'), ({},'fast','suspect'),
    ({'analysis_source':'coarse'},'standard','suspect'),
    ({'analysis_source':None},'standard','suspect'),
    ({'review_status':'goal'},'fast','must'),
    ({'review_status':'excluded'},'standard','excluded'),
    ({'review_status':'pending'},'standard','must'),
    ({'review_status':'deferred'},'standard','must'),
    ({'review_status':'second_review'},'standard','must'),
    ({'review_status':'excluded','review_reason':'auto_rim_check','rebound':True},'standard','excluded'),
    ({'review_status':'excluded','review_reason':'auto_rim_check','rebound':True},'fast','suspect'),
    ({'review_status':'excluded','review_reason':'auto_rim_check','rim_check':{'status':'rejected','reason':'no_entry'}},'standard','suspect'),
    ({'evidence_conflict':True},'standard','suspect'),
    ({'tier_calibration':{'samples':7,'median':10}},'standard','suspect'),
    ({'tier_calibration':{'samples':8,'median':0}},'standard','suspect'),
    ({'tier_calibration':{'samples':8,'median':float('nan')}},'standard','suspect'),
    ({'rim_check':{'status':'made','rebound':False,'net_motion':2.999}},'standard','suspect'),
    ({'rim_check':{'status':'made','rebound':False,'net_motion':float('nan')}},'standard','suspect'),
    ({'rim_check':{'status':'made','net_motion':10}},'standard','suspect'),
    ({'lateral_exit':True},'standard','suspect'),
])
def test_classification_contract(change, mode, tier):
    assert classify(evidence(**change),mode,'r2-v1')['tier']==tier


def test_missing_and_unknown_version_are_suspect():
    for item in [None, {}, 'not json', [], {'rim_check':[]}]:
        assert classify(item)['tier']=='suspect'
    assert classify(evidence(),rule_version='future')['tier']=='suspect'


def row(cid, t=500, e=None):
    return dict(id=cid,event_time_ms=t,default_start_ms=max(0,t-100),default_end_ms=t+100,
                detector_version='test',evidence_json=json.dumps(e or {}))


@pytest.fixture
def project(tmp_path):
    service=EngineService()
    root=tmp_path/'project'
    service.create_project(dict(name='tiers',root_path=str(root)))
    store=ProjectStore(root)
    source=tmp_path/'source.mp4';source.write_bytes(b'video')
    video=store.link_video(dict(source_path=str(source),source_size_bytes=5,source_mtime_ns=source.stat().st_mtime_ns,
                               duration_ms=30000,width=1920,height=1080,fps=30))
    store.replace_candidates(video['id'],[row('c1',500),row('c2',5000)])
    a=store.create_player('小王')['id'];b=store.create_player('囧')['id']
    yield service,store,video,a,b
    service.shutdown()


def test_calibration_is_per_batch_not_pooled_and_manual_undo(project):
    _,store,v,_,_=project
    rows=[row('r'+str(i),i*1000+500,evidence()) for i in range(8)]
    store.replace_candidates(v['id'],rows)
    assert {c['tier'] for c in store.list_candidates()}=={'must'}
    store.review_candidate('r0','excluded')
    assert store.list_candidates()[0]['tier_source']=='user'
    store.review_candidate('r0','pending')
    assert store.list_candidates()[0]['tier']=='must'
    store.replace_candidates(v['id'],rows[:7])
    assert {c['tier'] for c in store.list_candidates()}=={'suspect'}
    assert store.project()['tier_rule_version']=='r2-v1'


def test_legacy_migration_once_even_if_old_column_survives(project):
    _,store,_,a,_=project
    store.review_candidate('c1','goal',reason='made')
    reviewed_at=store.list_candidates()[0]['reviewed_at']
    # Recreate the actual pre-multitag table layout, not an empty new-project migration.
    with sqlite3.connect(store.db_path) as db:
        db.execute('DROP TABLE candidate_tags');db.execute('DROP TABLE schema_migrations')
        db.execute('UPDATE candidate_reviews SET player_id=? WHERE candidate_id=?',(a,'c1'))
    assert store.list_candidates()[0]['tags']==[{'id':a,'name':'小王'}]
    migrated=store.list_candidates()[0]
    assert migrated['tier']=='must' and migrated['tier_source']=='user'
    assert migrated['reviewed_at']==reviewed_at
    store.set_candidate_players('c1',[])
    with sqlite3.connect(store.db_path) as db:
        db.execute('UPDATE candidate_reviews SET player_id=? WHERE candidate_id=?',(a,'c1'))
    assert ProjectStore(store.root).list_candidates()[0]['tags']==[]
    assert ProjectStore(store.root).list_candidates()[0]['tags']==[]


def test_tag_order_atomic_batch_and_concurrent_add(project):
    _,store,_,a,b=project
    store.set_candidate_players('c1',[a,b,a])
    assert [t['id'] for t in store.list_candidates()[0]['tags']]==[a,b]
    with pytest.raises(LookupError):
        store.set_candidates_players(['c1','missing'],[b])
    assert store.list_candidates()[0]['player_id']==a
    store.set_candidate_players('c1',[])
    with ThreadPoolExecutor(2) as pool:
        futures=[pool.submit(store.add_candidate_player,'c1',p) for p in [a,b]]
        for future in futures: assert future.result()==1
    assert {t['id'] for t in store.list_candidates()[0]['tags']}=={a,b}
    store.set_candidate_players('c1',[a,b]);store.delete_player(a)
    assert store.list_candidates()[0]['player_id']==b
    with store.connect() as db:
        assert db.execute('SELECT player_id FROM candidate_reviews WHERE candidate_id="c1"').fetchone()[0]==b


def test_reanalysis_preserves_all_tags_human_review_and_ambiguous_does_not_copy(project):
    _,store,v,a,b=project
    store.set_candidate_players('c1',[a,b]);store.review_candidate('c1','goal',reason='made')
    before=store.list_candidates()[0]
    store.replace_candidates(v['id'],[row('new',550)])
    after=store.list_candidates()[0]
    assert [t['id'] for t in after['tags']]==[a,b]
    assert after['tier']=='must' and after['reviewed_at']==before['reviewed_at']
    store.replace_candidates(v['id'],[row('left',500),row('right',600)])
    store.set_candidate_players('left',[a]);store.set_candidate_players('right',[b])
    store.replace_candidates(v['id'],[row('middle',550)])
    assert store.list_candidates()[0]['tags']==[]


def test_scope_excluded_tag_and_snapshot_do_not_drift(project):
    service,store,v,a,b=project
    store.set_candidate_players('c1',[a,b]);store.review_candidate('c1','excluded')
    store.set_candidate_players('c2',[a]);store.review_candidate('c2','goal')
    payload=dict(tiers=['excluded'],tags=[b])
    listed=service.list_candidates(dict(project_root=str(store.root),**payload))['candidates']
    _,_,snapshot=service._export_candidate_snapshot(store,None,payload)
    assert [c['id'] for c in listed]==[c['id'] for c in snapshot]==['c1']
    assert [t['id'] for t in snapshot[0]['tags']]==[a,b]
    assert [t['id'] for t in snapshot[0]['export_tags']]==[b]
    store.set_candidate_players('c1',[]);store.review_candidate('c1','goal')
    assert snapshot[0]['tier']=='excluded' and len(snapshot[0]['tags'])==2
    assert len(filter_candidates(store.list_candidates(),['must'],None))==2
    assert filter_candidates(store.list_candidates(),[],None)==[]
    assert filter_candidates(store.list_candidates(),None,[])==[]
    with pytest.raises(ProtocolError):
        service._export_candidate_snapshot(store,None,dict(tiers=['invalid']))


def test_multitag_export_groups_once_and_selected_tags_only(project,tmp_path,monkeypatch):
    service,store,_,a,b=project
    store.set_candidate_players('c1',[a,b]);store.review_candidate('c1','excluded')
    _,_,snapshot=service._export_candidate_snapshot(store,None,dict(tiers=['excluded'],tags=None))
    snapshot[0]["source_path"] = "/unused/source.mp4"
    observed=[]
    def export(group,*args,**kwargs):
        observed.append([c['id'] for c in group])
        return dict(files=[],clip_files=[],duration_ms=200,processing_ms=0,merged_overlap_count=0)
    monkeypatch.setattr('engine.python.basketball_engine.service.export_goal_clips',export)
    service._export_merged_per_player(store,snapshot,tmp_path/'out',set())
    assert observed==[['c1'],['c1']]


def test_protocol_tag_mutations_validate_and_rollback(project):
    service,store,_,a,b=project
    base=dict(project_root=str(store.root),candidate_id='c1')
    assert service.handle('set_candidate_players',dict(base,player_ids=[a]))=={'updated':1}
    service.handle('add_candidate_player',dict(base,player_id=b))
    service.handle('remove_candidate_player',dict(base,player_id=a))
    assert store.list_candidates()[0]['player_id']==b
    with pytest.raises(ProtocolError):service.handle('set_candidate_players',dict(base,player_ids=None))


def test_saved_baseline_calibration_and_string_conflict():
    e=evidence();e.pop('tier_calibration')
    e['rim_check']['experiment']={'net_calibration':{'scope':'analysis_run_baseline_made','samples':8,'median':10}}
    assert classify(e)['tier']=='must'
    e['evidence_conflict']='true'
    assert classify(e)['tier']=='suspect'


def test_concurrent_first_open_of_legacy_project(project):
    _,store,_,a,_=project
    with sqlite3.connect(store.db_path) as db:
        db.execute('DROP TABLE candidate_tags');db.execute('DROP TABLE schema_migrations')
        db.execute('ALTER TABLE projects DROP COLUMN tier_rule_version')
        db.execute('UPDATE candidate_reviews SET player_id=? WHERE candidate_id=?',(a,'c1'))
    with ThreadPoolExecutor(3) as pool:
        results=list(pool.map(lambda _: ProjectStore(store.root).list_candidates(),range(3)))
    assert all(rows[0]['tags']==[{'id':a,'name':'小王'}] for rows in results)
    with store.connect() as db:
        assert db.execute('SELECT count(*) FROM schema_migrations WHERE name="candidate_tags_v1"').fetchone()[0]==1


from tests.test_export_by_player import tagged_project


def test_actual_excluded_tag_export(tagged_project,tmp_path):
    service,store,root,ffprobe,(a,b)=tagged_project
    store.add_candidate_player('c1000',b)
    store.review_candidate('c1000','excluded')
    payload=dict(project_root=str(root),mode='merge_by_player',tiers=['excluded'],tags=[b],output_dir=str(tmp_path/'excluded-out'))
    _,_,snapshot=service._export_candidate_snapshot(store,None,payload)
    assert [c['id'] for c in snapshot]==['c1000']
    result=service._execute_export(dict(payload,candidate_snapshot=snapshot))
    assert len(result['files'])==1
    import subprocess
    info=json.loads(subprocess.check_output([ffprobe,'-v','error','-show_entries','format=duration','-of','json',result['files'][0]]))
    assert abs(float(info['format']['duration'])-1)<.3
    service.shutdown()


def test_reanalysis_reserves_exact_matches_and_rejects_new_event_ties(project):
    _,store,v,a,b=project
    store.set_candidate_players('c1',[a,b]);store.review_candidate('c1','goal')
    store.replace_candidates(v['id'],[row('near',450),row('c1',500)])
    rows={c['id']:c for c in store.list_candidates()}
    assert rows['near']['tags']==[]
    assert len(rows['c1']['tags'])==2
    store.replace_candidates(v['id'],[row('c1',500)])
    store.replace_candidates(v['id'],[row('tie1',450),row('tie2',550)])
    assert all(c['tags']==[] and c['review_status']=='pending' for c in store.list_candidates())


def test_batch_protocol_and_frozen_job_scope(project,monkeypatch):
    import threading
    service,store,_,a,b=project
    base={'project_root':str(store.root)}
    service.handle('set_candidates_players',dict(base,candidate_ids=['c1','c2'],player_ids=[a]))
    service.handle('add_candidates_player',dict(base,candidate_ids=['c1','c2'],player_id=b))
    service.handle('remove_candidates_player',dict(base,candidate_ids=['c2'],player_id=a))
    assert [t['id'] for t in store.list_candidates()[1]['tags']]==[b]
    store.review_candidate('c1','excluded');store.review_candidate('c2','goal')
    entered=threading.Event()
    monkeypatch.setattr(service,'_run_export',lambda *args: entered.set())
    job=service.start_export(dict(base,mode='separate',tiers=['excluded'],tags=[b]))['job']
    assert entered.wait(2)
    checkpoint=service._decode_checkpoint(store.get_job(job['id']))
    assert checkpoint['tiers']==['excluded'] and checkpoint['tags']==[b]
    assert checkpoint['tier_rule_version']=='r2-v1'
    assert [c['id'] for c in checkpoint['candidate_snapshot']]==['c1']
    store.set_candidate_players('c1',[]);store.review_candidate('c1','goal')
    saved=service._decode_checkpoint(store.get_job(job['id']))['candidate_snapshot'][0]
    assert saved['tier']=='excluded' and len(saved['tags'])==2


def _make_pre_tiers_database(store):
    with sqlite3.connect(store.db_path) as db:
        db.execute('DROP TABLE candidate_tags')
        db.execute('DROP TABLE schema_migrations')
        db.execute('ALTER TABLE projects DROP COLUMN tier_rule_version')


def test_old_database_backed_up_before_initialize_and_never_overwritten(project):
    _,store,_,a,_=project
    store.set_candidate_player('c1',a);store.review_candidate('c1','goal')
    _make_pre_tiers_database(store)
    store.initialize()
    backup=store.root/'project.db.pre-tiers-v1.bak'
    saved=backup.read_bytes()
    with sqlite3.connect(backup) as db:
        assert 'tier_rule_version' not in {r[1] for r in db.execute('PRAGMA table_info(projects)')}
        assert not db.execute("SELECT 1 FROM sqlite_master WHERE name='candidate_tags'").fetchone()
        assert db.execute('SELECT status,player_id FROM candidate_reviews WHERE candidate_id="c1"').fetchone()==('goal',a)
    store.review_candidate('c1','excluded');store.initialize()
    assert backup.read_bytes()==saved


def test_backup_failure_stops_all_migrations(project,monkeypatch):
    import os
    _,store,_,_,_=project
    _make_pre_tiers_database(store)
    with sqlite3.connect(store.db_path) as db: before=list(db.iterdump())
    def denied(*args): raise PermissionError('backup publication denied')
    monkeypatch.setattr(os,'link',denied)
    with pytest.raises(PermissionError):store.initialize()
    with sqlite3.connect(store.db_path) as db: assert list(db.iterdump())==before
    assert not list(store.root.glob('.pre-tiers-*.tmp'))


def test_backup_includes_committed_wal_data(project):
    _,store,_,_,_=project
    _make_pre_tiers_database(store)
    with sqlite3.connect(store.db_path) as writer:
        writer.execute('PRAGMA journal_mode=WAL')
        writer.execute('UPDATE candidate_reviews SET note="committed in WAL" WHERE candidate_id="c1"')
        writer.commit()
        assert store.db_path.with_name('project.db-wal').stat().st_size>0
        store.list_candidates()
        backup=store.root/'project.db.pre-tiers-v1.bak'
        with sqlite3.connect(backup.as_uri()+'?mode=ro&immutable=1',uri=True) as saved:
            assert saved.execute('SELECT note FROM candidate_reviews WHERE candidate_id="c1"').fetchone()[0]=='committed in WAL'


@pytest.mark.parametrize('samples,expected', [(8, 'must'), (7, 'suspect')])
def test_legacy_read_calibrates_in_memory_without_writing_database(project, samples, expected):
    import hashlib
    _, store, video, _, _ = project
    # Start with already migrated schema, but real legacy evidence has no saved baseline.
    with store.connect() as con:
        con.execute('DELETE FROM candidate_reviews')
        con.execute('DELETE FROM candidates')
        for i in range(samples):
            old = evidence()
            old.pop('tier_calibration')
            con.execute("""INSERT INTO candidates(id,video_id,event_time_ms,default_start_ms,default_end_ms,
                review_start_ms,review_end_ms,detector_version,evidence_json,created_at,updated_at)
                VALUES(?,?,?,0,2000,0,2000,'legacy',?,'a','a')""",(f'old{i}',video['id'],i*1000,json.dumps(old)))
        con.execute("INSERT INTO candidate_reviews(candidate_id,status,reason,updated_at) VALUES('old0','excluded','rim_out','a')")
    other = store.link_video({**video, 'id': 'other-video'})
    with store.connect() as con:
        con.execute("UPDATE candidates SET video_id=? WHERE event_time_ms>=4000", (other['id'],))
    before = (store.db_path.stat().st_mtime_ns, hashlib.sha256(store.db_path.read_bytes()).hexdigest())
    for _ in range(2):
        rows = store.list_candidates(video['id'])
        assert rows[0]['tier'] == 'excluded' and rows[0]['tier_source'] == 'user'
        assert {r['tier'] for r in rows[1:]} == {expected}
        assert all('tier_calibration' not in json.loads(r['evidence_json']) for r in rows)
        assert (store.db_path.stat().st_mtime_ns, hashlib.sha256(store.db_path.read_bytes()).hexdigest()) == before


@pytest.mark.parametrize('motion', [0, 3])
def test_legacy_fallback_keeps_saved_calibration_and_zero_baseline_suspect(project, motion):
    _, store, video, _, _ = project
    store.replace_candidates(video['id'],[row(str(i),500+i*1000,evidence()) for i in range(8)])
    with store.connect() as con:
        for i in range(8):
            old=evidence(rim_check=dict(status='made',rebound=False,net_motion=motion))
            old.pop('tier_calibration')
            if i==0: old['tier_calibration']={'samples':7,'median':10}
            con.execute('UPDATE candidates SET evidence_json=? WHERE id=?',(json.dumps(old),str(i)))
    rows=store.list_candidates()
    assert rows[0]['tier_reason']=='missing_calibration'  # Saved baseline is never overwritten.
    assert {c['tier'] for c in rows[1:]}=={'suspect' if motion==0 else 'must'}
