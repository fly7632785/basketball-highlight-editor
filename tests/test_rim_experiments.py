import importlib.util
import json
import os
from pathlib import Path

import pytest

from basketball_highlight import rim_experiments as ex
from basketball_highlight.rim_check import keep_unless_seen
from engine.python.basketball_engine.adapters.analysis import apply_rim_checks, build_rim_check_command
from .test_rim_check import RIM, ball, fall


def judge(frames, config=ex.RimExperiments(), rim=RIM, fps=30):
    return ex.judge_candidates([{"rim":rim}], [{"frames":frames}], config=config, fps=fps)[0]


def test_config_hash_env_validation_and_default(monkeypatch):
    monkeypatch.setenv(ex.ENV_NAME, '{"min_rim_width_px":24}')
    assert ex.load_config().min_rim_width_px == 24
    assert ex.load_config('{}').is_default
    assert ex.load_config('{"min_rim_width_px":30}').config_hash == ex.RimExperiments().config_hash
    for value in ['null', '{"unknown":1}', '{"track_mode":"magic"}', '{"net_weak":1}', '{"min_rim_width_px":NaN}', '{"net_min_samples":7}', '{"net_weak_ratio":2}']:
        with pytest.raises((TypeError,ValueError)):
            ex.load_config(value)


def test_small_rim_switch_both_sides_and_no_fake_cache_detection():
    rim={**RIM,"width":26}
    frames=[[] if i in (6,7) else [ball(0,-1.5+i*.25,rim=rim)] for i in range(16)]
    assert judge(frames,rim=rim)["status"] == "skipped"
    enabled=judge(frames,ex.RimExperiments(min_rim_width_px=24),rim)
    assert enabled["status"] == "made"
    assert "min_rim_width_px" in enabled["experiment"]["matched_switches"]
    assert judge(frames,ex.RimExperiments(min_rim_width_px=24),{**rim,"width":23})["status"] == "skipped"
    cached=ex.judge_candidates([{"rim":rim}],[{"status":"skipped","reason":"small_rim","rim_width_px":26}],config=ex.RimExperiments(min_rim_width_px=24))[0]
    assert cached["status"]=="skipped"
    assert "small_rim_cache_requires_detection" in cached["experiment"]["notes"]


def broken_fall(start=20):
    frames=[[] for _ in range(start+6)]
    for i,y in enumerate([-1.4,-1.1,-.8,-.5,-.2]):frames[i]=[ball(0,y)]
    for i,y in enumerate([.2,.5,.8,1.1,1.4,1.7],start):frames[i]=[ball(0,y)]
    return frames


def test_fable_stitch_positive_gap_limit_fps_and_ambiguity():
    config=ex.RimExperiments(track_mode="fable_stitch")
    assert judge(broken_fall())["status"]=="unsure"
    new=judge(broken_fall(),config)
    assert new["status"]=="made"
    assert new["experiment"]["stitches"][0]["gap_frames"]==16
    assert judge(broken_fall(42),config)["status"]=="unsure"
    assert judge(broken_fall(),config,fps=60)["status"]=="unsure"
    assert judge(broken_fall(),config,fps=None)["status"]=="unsure"
    tracks=[[{"i":i,"x":0,"y":-.5+i*.1} for i in range(3)], [{"i":20+i,"x":0,"y":.2+i*.3} for i in range(3)]]
    _,events=ex.stitch_tracks(tracks+[tracks[1]],30)
    assert events==[]


def test_astra_only_recovers_existing_anchored_crossing(monkeypatch):
    old={"version":"rim-dense-v2","status":"rejected","reason":"no_exit","x_cross":.1,"cross_frame":4}
    new={**old,"status":"made","reason":None}
    def raw(item,result,config,mode="off",fps=None):return (dict(old) if mode=="off" else dict(new)),[]
    monkeypatch.setattr(ex,"_raw_check",raw)
    cfg=ex.RimExperiments(track_mode="astra_fill")
    fixed=judge([],cfg)
    assert fixed["status"]=="made"
    new["x_cross"]=.4
    assert judge([],cfg)["status"]=="unsure"
    new["x_cross"]=.1;old["reason"]="no_crossing"
    assert judge([],cfg)["status"]=="unsure"


def test_consecutive_filter_keeps_intermittent_motion_but_drops_static():
    intermittent=[[{"x":0,"y":0,"conf":.9}]]*3+[[]]+[[{"x":0,"y":0,"conf":.9}]]*3
    assert sum(map(len,ex.consecutive_static(intermittent)))==6
    static=[[{"x":0,"y":0,"conf":.9}]]*6
    assert sum(map(len,ex.consecutive_static(static)))==0


def test_stitch_safety_envelope_does_not_overrule_negative_or_add_rejection(monkeypatch):
    old={"status":"rejected","reason":"rebound"};new={"status":"made","reason":None}
    monkeypatch.setattr(ex,"_raw_check",lambda item,raw,config,mode="off",fps=None: (dict(old) if mode=="off" else dict(new),[]))
    cfg=ex.RimExperiments(track_mode="fable_stitch")
    assert judge([],cfg)["reason"]=="conflicting_negative_needs_review"
    old.update(status="made",reason=None);new.update(status="rejected",reason="rebound")
    assert judge([],cfg)["reason"]=="new_negative_needs_review"


def test_net_weak_missing_and_calibration_limits(monkeypatch):
    config=ex.RimExperiments(net_weak=True)
    def raw(item,result,config,mode="off",fps=None):return {"status":"made","reason":None,"net_motion":result.get("motion")},[]
    monkeypatch.setattr(ex,"_raw_check",raw)
    def batch(motions):return ex.judge_candidates([{}]*len(motions),[{"motion":m} for m in motions],config=config)
    checked=batch([10]*8+[1,None])
    assert checked[-2]["reason"]=="net_weak" and checked[-2]["status"]=="unsure"
    assert checked[-1]["reason"]=="net_missing"
    assert checked[0]["status"]=="made"
    assert batch([10]*6+[1])[-1]["status"]=="made"


def test_side_exit_support_both_paths_and_rebound(monkeypatch):
    raw={"status":"rejected","reason":"off_center","x_exit":1,"track_points":4,"track_span":1.5}
    monkeypatch.setattr(ex,"_raw_check",lambda *a,**kw:(dict(raw),[]))
    assert judge([])["status"]=="rejected"
    config=ex.RimExperiments(supported_side_exit=True)
    assert judge([],config)["reason"]=="short_side_exit_track"
    raw.update(track_points=10,track_span=1)
    assert judge([],config)["status"]=="rejected"
    raw.update(track_points=4,rebound=True)
    assert judge([],config)["reason"]=="rebound"


def test_cli_scheduling_and_adapter_config_metadata():
    path=Path(__file__).resolve().parents[1]/"scripts/verify_rim_crossing.py"
    spec=importlib.util.spec_from_file_location("rim_script_test",path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    inputs=[{"time":1,"rim":{**RIM,"width":26}}]
    assert len(module.build_jobs(inputs,30,100,1920,1080)[0])==0
    assert len(module.build_jobs(inputs,30,100,1920,1080,24)[0])==1
    config=ex.RimExperiments(net_weak=True)
    matches=[{"time":1}]
    apply_rim_checks(matches,inputs,None,config=config)
    assert matches[0]["rim_check"]["experiment"]["config_hash"]==config.config_hash
    command=build_rim_check_command(Path('.'),Path('video'),Path('model'),Path('input'),Path('out'),experiment_config=config)
    assert json.loads(command[-1])["net_weak"] is True


@pytest.mark.skipif(not os.environ.get("BHE_RIM_REPLAY_DATA"),reason="Private frame cache not distributed")
def test_default_replays_every_private_cached_candidate_exactly():
    path=Path(__file__).resolve().parents[1]/"scripts/replay_rim_experiments.py"
    spec=importlib.util.spec_from_file_location("rim_replay_test",path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    report=module.replay(Path(os.environ["BHE_RIM_REPLAY_DATA"]),ex.RimExperiments())
    assert report["dense_frames_candidates"] > 0
    assert report["differences"]==0
    print(json.dumps({k:v for k,v in report.items() if k!="changed"}))


def test_service_passes_frozen_config_and_separates_detection_cache(tmp_path,monkeypatch):
    from engine.python.basketball_engine import service as module
    service=module.EngineService()
    calls=[]
    def fake_run(commands,output_path,*args,**kwargs):
        command=commands[0]
        config=json.loads(command[command.index('--experiment-config')+1])
        calls.append((str(output_path),config))
        output={'fps':30,'results':[{'frames':fall(hidden={6,7})}]}
        Path(output_path).write_text(json.dumps(output))
        return {'refined':output,'logs':[]}
    monkeypatch.setattr(module,'run_pipeline',fake_run)
    def verify(value):
        monkeypatch.setenv(ex.ENV_NAME,json.dumps(value))
        matches=[{'time':1,'overlay':{'rim':RIM}}];pipeline={'logs':[]}
        service._verify_rim_crossings(repo_root=tmp_path,source_video=tmp_path/'video',model_path=tmp_path/'model',run_root=tmp_path/'cache',matches=matches,on_stage=lambda *a:None,cancel_event=None,job_id='test',pipeline=pipeline)
        assert matches[0]['rim_check']['experiment']['config_hash']==ex.load_config(value).config_hash
        return pipeline
    verify({})
    cached=verify({'net_weak':True})
    assert len(calls)==1 and cached['cache_hits']==1
    verify({'min_rim_width_px':24})
    verify({'track_mode':'fable_stitch'})
    assert len(calls)==3
    assert len({p for p,_ in calls})==3
    assert calls[-1][1]['track_mode']=='fable_stitch'
