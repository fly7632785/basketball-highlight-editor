import importlib.util
import json
import os
from pathlib import Path

import pytest

from basketball_highlight import rim_experiments as ex
from engine.python.basketball_engine.adapters.analysis import apply_rim_checks, build_rim_check_command
from .test_rim_check import RIM, ball, fall


def judge(frames, config=ex.RimExperiments(), rim=RIM, fps=30):
    return ex.judge_candidates([{"rim":rim}], [{"frames":frames}], config=config, fps=fps)[0]


def test_config_hash_env_validation_and_default(monkeypatch):
    monkeypatch.delenv(ex.ENV_NAME, raising=False)
    assert ex.load_config() == ex.RimExperiments(track_mode="fable_stitch", visible_crossing=True)
    monkeypatch.setenv(ex.ENV_NAME, '{"visible_crossing":true}')
    assert ex.load_config() == ex.RimExperiments(visible_crossing=True)
    assert ex.load_config('{}').is_default
    assert ex.load_config('{"visible_crossing":false,"track_mode":"off"}').config_hash == ex.RimExperiments().config_hash
    for value in [
        'null', '{"unknown":1}', '{"track_mode":"astra_fill"}', '{"visible_crossing":1}',
        '{"min_rim_width_px":24}', '{"net_weak":true}', '{"supported_side_exit":true}',
        '{"visible_side_miss":true}', '{"retry_rim_window":true}', '{"static_false_ball":true}',
        '{"below_rim_movement":true}', '{"wide_low_movement":true}',
        '{"rim_fragment_reconnect":true}', '{"strong_path_weak_net":true}',
    ]:
        with pytest.raises((TypeError, ValueError)):
            ex.load_config(value)


def test_small_rim_still_skips():
    rim = {**RIM, "width": 26}
    frames = fall(hidden={6, 7})
    config = ex.RimExperiments(track_mode="fable_stitch", visible_crossing=True)
    assert judge(frames, config=config, rim=rim)["status"] == "skipped"


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


def test_stitch_safety_envelope_does_not_overrule_negative_or_add_rejection(monkeypatch):
    old={"status":"rejected","reason":"rebound"};new={"status":"made","reason":None}
    monkeypatch.setattr(ex,"_raw_check",lambda item,raw,mode="off",fps=None: (dict(old) if mode=="off" else dict(new),[]))
    cfg=ex.RimExperiments(track_mode="fable_stitch")
    assert judge([],cfg)["reason"]=="conflicting_negative_needs_review"
    old.update(status="made",reason=None);new.update(status="rejected",reason="rebound")
    assert judge([],cfg)["reason"]=="new_negative_needs_review"


def test_visible_crossing_only_promotes_complete_centered_crossings(monkeypatch):
    from engine.python.basketball_engine.tiers import classify

    visible = {
        "status": "rejected", "reason": "not_occluded", "track_points": 30,
        "entry": True, "reached_net_bottom": True, "rebound": False,
        "x_cross": .08, "x_exit": -.12, "net_motion": 2,
    }
    calibration = [{"status": "made", "reason": None, "net_motion": 3}] * 8
    candidates = [
        visible,
        {**visible, "x_cross": .4, "x_exit": .5, "net_motion": -1},
        {**visible, "net_motion": None},
        {**visible, "reached_net_bottom": False},
    ]
    monkeypatch.setattr(ex, "_raw_check", lambda item, raw, mode="off", fps=None: (raw, []))
    rows = calibration + candidates
    inputs = [{"time": i, "rim": RIM} for i in range(len(rows))]
    baseline = ex.judge_candidates(inputs, rows)
    config = ex.RimExperiments(visible_crossing=True)
    changed = ex.judge_candidates(inputs, rows, config=config)
    assert [result["status"] for result in baseline[-4:]] == ["unsure"] * 4
    assert [result["status"] for result in changed[-4:]] == ["made", "unsure", "unsure", "unsure"]
    assert changed[-4]["experiment"]["matched_switches"] == ["visible_crossing"]
    assert classify({"analysis_source": "refined", "rim_check": changed[-4]})["tier"] == "must"
    assert not ex._is_visible_crossing({**visible, "status": "unsure"}, None)


def test_cli_scheduling_and_adapter_config_metadata():
    path=Path(__file__).resolve().parents[1]/"scripts/verify_rim_crossing.py"
    spec=importlib.util.spec_from_file_location("rim_script_test",path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    inputs=[{"time":1,"rim":{**RIM,"width":26}}]
    assert len(module.build_jobs(inputs,30,100,1920,1080)[0])==0
    config=ex.RimExperiments(visible_crossing=True)
    matches=[{"time":1}]
    apply_rim_checks(matches,inputs,None,config=config)
    assert matches[0]["rim_check"]["experiment"]["config_hash"]==config.config_hash
    command=build_rim_check_command(Path('.'),Path('video'),Path('model'),Path('input'),Path('out'),experiment_config=config)
    assert json.loads(command[-1])["visible_crossing"] is True


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
    cached=verify({'visible_crossing':True})
    assert len(calls)==1 and cached['cache_hits']==1
    verify({'track_mode':'fable_stitch'})
    assert len(calls)==2
    assert len({p for p,_ in calls})==2
    assert calls[-1][1]['track_mode']=='fable_stitch'
    # Repair a cache produced by the old enabled-script serialization bug.
    broken_path=Path(calls[0][0]);broken=json.loads(broken_path.read_text())
    broken['results'][0]['frames']=16
    broken_path.write_text(json.dumps(broken))
    repaired=verify({})
    assert len(calls)==3 and calls[-1][0]==calls[0][0]
    assert any('cached raw frames missing' in line for line in repaired['logs'])
    assert isinstance(json.loads(broken_path.read_text())['results'][0]['frames'],list)


def test_enabled_detection_script_keeps_raw_frames_for_engine_rejudging(tmp_path,monkeypatch):
    from types import SimpleNamespace
    import cv2
    import numpy as np
    path=Path(__file__).resolve().parents[1]/'scripts/verify_rim_crossing.py'
    spec=importlib.util.spec_from_file_location('rim_script_serialization',path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    video=tmp_path/'source.avi'
    writer=cv2.VideoWriter(str(video),cv2.VideoWriter_fourcc(*'MJPG'),10,(64,64))
    assert writer.isOpened()
    for _ in range(20):writer.write(np.zeros((64,64,3),dtype=np.uint8))
    writer.release()
    class Detector:
        def predict(self,crops,**kwargs):
            return [SimpleNamespace(boxes=[],names={}) for _ in crops]
    monkeypatch.setattr(module,'select_device',lambda _: 'cpu')
    monkeypatch.setattr(module,'current_device',lambda: 'cpu')
    monkeypatch.setattr(module,'load_yolo_model',lambda _:Detector())
    inputs=[{'time':1,'rim':{'center_x':32,'rim_y':25,'width':36,'height':12}}]
    candidates=tmp_path/'input.json';candidates.write_text(json.dumps({'candidates':inputs}))
    output=tmp_path/'result.json'
    module.main(SimpleNamespace(video=video,model=tmp_path/'unused.pt',candidates=candidates,output=output,conf=.05,batch=16,device='cpu',experiment_config='{"visible_crossing":true}'))
    cached=json.loads(output.read_text())
    assert isinstance(cached['results'][0]['frames'],list)
    assert len(cached['results'][0]['frames'])==20
    matches=[{'time':1}]
    apply_rim_checks(matches,inputs,cached,config=ex.RimExperiments(visible_crossing=True))
    assert matches[0]['rim_check']['frames']==20
    assert matches[0]['rim_check']['reason']=='no_crossing'
