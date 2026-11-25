from pathlib import Path
import shutil
import subprocess
import json

import pytest

from engine.python.basketball_engine.adapters import export
from engine.python.basketball_engine.adapters.portrait import (
    _crowd_observations, clean_observations, compose_portrait, portrait_filter, PortraitTracker, SAMPLE_FPS,
)
from engine.python.basketball_engine.adapters.analysis import PipelineCancelled


def _ball(x):
    return [x-10, 400, x+10, 420]


def test_fast_follow_requires_consistent_ball_motion_and_keeps_the_pan_smooth():
    slow = [640.] * 14 + [640 + i * 12 for i in range(22)] + [892.] * 14
    fast = [640.] * 14 + [640 + i * 90 for i in range(9)] + [1360.] * 27
    for points, is_fast in [(slow, False), (fast, True)]:
        plan = compose_portrait([_ball(x) for x in points], [], 1920, 1080, [])
        centers = plan['centers']
        w = plan['crop_width']
        speed = [(b-a)*SAMPLE_FPS/w for a,b in zip(centers,centers[1:])]
        accel = [(b-a)*SAMPLE_FPS for a,b in zip(speed,speed[1:])]
        # Kernel transitions can settle by a few pixels. Reject visible oscillation.
        assert sum(max(0, -v) for v in speed)/SAMPLE_FPS < .012
        assert min(speed) >= -.035
        assert max(speed) <= (1.602 if is_fast else .602)
        assert max(map(abs,accel)) <= (3.603 if is_fast else .803)
        assert (max(plan['fast']) > .5) is is_fast
        if is_fast:
            assert max(speed) > .8
            assert all(abs(x-c) < w/2 for x,c in zip(points,centers))
    isolated = [1000.] * 12 + [1800.] + [1000.] * 12
    assert clean_observations(isolated,606)[12] is None
    plan = compose_portrait([_ball(x) for x in isolated], [], 1920, 1080, [])
    assert max(plan['centers'])-min(plan['centers']) < 1
    assert max(plan['fast']) == 0


def test_sparse_clip_can_reacquire_ball_after_following_a_crowd_and_then_hold_hoop():
    hoop = [1030,475,1070,515]
    balls = [None]*120
    balls[42:54] = [_ball(700+i*13) for i in range(12)]
    players = [[550,540,620,700],[650,535,720,680]]
    people = [players if i % 2 == 0 and i < 80 else None for i in range(120)]
    plan = compose_portrait(balls,[[hoop]]*20,1920,1080,[],people=people)
    assert plan['tracking_coverage'] == .1
    assert [plan['sources'][i] for i in (8,48,71,104)] == ['crowd','ball','crowd','hoop']
    assert plan['centers'][8] < 700
    assert plan['centers'][-1] == pytest.approx(1050,abs=.04*606)
    assert max(abs(a-b) for a,b in zip(plan['centers'],plan['centers'][1:])) <= .602*606/10


def test_crowd_favors_near_active_players_and_ignores_people_above_court():
    hoop = [980,440,1020,480]
    people = [
        [[900,500,960,640],[1300,520,1360,700],[1750,100,1800,300]],
        None,
        [[950,500,1010,640],[1300,520,1360,700],[1750,100,1800,300]],
    ]
    first, missing, second = _crowd_observations(people,hoop,1920,1080)
    assert missing is None
    assert 930 < first < 1130
    assert second < first  # the nearer mover outweights the stationary player


def test_crop_interpolates_and_handles_narrow_source():
    vf=portrait_filter([500,550,600],1920,1080)
    assert 'clip((t-0.000)*10,0,1)' in vf
    assert 'crop=606:1080' in vf
    assert 'scale=1080:1920' in vf
    assert 'crop=360:640' in portrait_filter([180],360,640)
    with pytest.raises(ValueError):
        portrait_filter([],1920,1080)


def test_original_does_not_construct_tracker(tmp_path,monkeypatch):
    def forbidden(*a,**k):
        pytest.fail('original export loaded tracking model')
    monkeypatch.setattr(PortraitTracker,'__init__',forbidden)
    monkeypatch.setattr(export,'run_encoded_ffmpeg',lambda build,path,*a,**k: (path.write_bytes(b'clip'),'libx264')[1])
    result=export.export_goal_clips([dict(source_path='source.mp4',event_time_ms=500,review_start_ms=0,review_end_ms=1000)],tmp_path,'separate')
    assert len(result['files'])==1


@pytest.mark.parametrize('effect,framing',[('none','portrait_916'), ('approach','portrait_916'),
                                           ('replay','portrait_916'), ('none','portrait_blur')])
def test_real_portrait_encode_preserves_audio_and_duration(tmp_path,monkeypatch,effect,framing):
    if not shutil.which('ffmpeg'):
        pytest.skip('ffmpeg unavailable')
    source=tmp_path/'source.mp4'
    subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','testsrc2=s=640x360:r=10:d=2',
                    '-f','lavfi','-i','sine=frequency=440:duration=2','-c:v','libx264','-c:a','aac',str(source)],check=True)
    monkeypatch.setattr(PortraitTracker,'__init__',lambda *a: None)
    # A 31 second moving crop used to exceed FFmpeg's expression depth.
    centers = [220 + i % 75 for i in range(310)]
    monkeypatch.setattr(PortraitTracker,'track',lambda *a: portrait_filter(centers,640,360))
    candidate=dict(source_path=str(source),event_time_ms=1200,review_start_ms=0,review_end_ms=2000,
                   width=640,height=360,fps=10,has_audio=True,trail=[[290,100],[320,150]],rim={'x':320,'y':140,'width':30})
    result=export.export_goal_clips([candidate],tmp_path/'out','separate',effect=effect,framing=framing)
    info=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',result['files'][0]]))
    video=next(s for s in info['streams'] if s['codec_type']=='video')
    assert (video['width'],video['height'])==(1080,1920)
    assert any(s['codec_type']=='audio' for s in info['streams'])
    assert abs(float(info['format']['duration'])-result['duration_ms']/1000)<.25


def test_invalid_framing_rejected_before_work(tmp_path):
    with pytest.raises(ValueError,match='INVALID_EXPORT_FRAMING'):
        export.export_goal_clips([],tmp_path,'separate',framing='unknown')


@pytest.mark.parametrize('fps,expected_reads', [(30, 10), (2, 2)])
def test_tracker_samples_ten_fps_uses_detected_rim_and_releases_on_cancel(monkeypatch, fps, expected_reads):
    import cv2
    from basketball_highlight.onnx_detector import Box, Result
    class Capture:
        released = False
        reads = 0
        def isOpened(self): return True
        def get(self, key):
            return {cv2.CAP_PROP_FRAME_WIDTH:1920, cv2.CAP_PROP_FRAME_HEIGHT:1080, cv2.CAP_PROP_FPS:fps, cv2.CAP_PROP_POS_MSEC:0}[key]
        def set(self,*args): pass
        def grab(self): return True
        def read(self):
            self.reads += 1
            return True, object()
        def release(self): self.released = True
    capture=Capture()
    monkeypatch.setattr(cv2,'VideoCapture',lambda *args:capture)
    class Model:
        calls=0
        def predict(self,*a,**k):
            self.calls+=1
            return [Result([Box(1,.9,[1400,300,1600,340])],{0:'ball',1:'hoop'})]
    tracker=PortraitTracker.__new__(PortraitTracker)
    tracker.model=Model();tracker.device='cpu'
    candidate=dict(source_path='source.mp4',review_start_ms=1000,review_end_ms=2000)
    result=tracker.track(candidate)
    assert tracker.model.calls==10
    assert capture.reads==expected_reads
    assert result.startswith("crop=606:1080:x='1197.0000'")  # stationary crop at the hoop
    assert capture.released
    capture.released=False
    with pytest.raises(PipelineCancelled):
        tracker.track(candidate,cancel_check=lambda:True)
    assert capture.released


@pytest.mark.parametrize('framing', ['portrait_916', 'portrait_blur'])
def test_portrait_service_checkpoint_retry_preserves_framing(tmp_path,monkeypatch,framing):
    from tests.test_export_job_validation import setup_export,wait_job
    service,store,source,payload=setup_export(tmp_path)
    observed=[]
    def fail_export(*args,**kwargs):
        observed.append(kwargs.get('framing'))
        raise OSError('intentional encode failure')
    import engine.python.basketball_engine.service as module
    monkeypatch.setattr(module,'export_goal_clips',fail_export)
    try:
        payload['framing']=framing
        job=service.start_export(payload)['job']
        assert wait_job(store,job['id'])['state']=='failed'
        assert service._decode_checkpoint(store.get_job(job['id']))['framing']==framing
        retry=service.retry_export(dict(project_root=str(store.root),job_id=job['id']))['job']
        assert wait_job(store,retry['id'])['state']=='failed'
        assert observed==[framing,framing]
    finally:
        service.shutdown()


def test_composition_rejects_floor_logo_and_preserves_hoop_at_each_goal():
    from engine.python.basketball_engine.adapters.portrait import compose_portrait, plausible_ball
    assert not plausible_ball([478,864,823,1010],1920)
    hoop = [980,580,1020,610]
    balls = [[600+i*5,600,620+i*5,620] for i in range(90)]
    plan = compose_portrait(balls,[[hoop]]*90,1920,1440,[2,7])
    assert plan['mode']=='crop'
    assert (plan['crop_width'], plan['crop_height'], plan['crop_y']) == (810, 1440, 0)
    for i,cx in enumerate(plan['centers']):
        if .5 <= i/SAMPLE_FPS <= 4 or i/SAMPLE_FPS >= 5.5:
            assert cx-plan['crop_width']/2 <= hoop[0]
            assert cx+plan['crop_width']/2 >= hoop[2]
    assert plan['crop_y'] <= hoop[1] < hoop[3] <= plan['crop_y']+plan['crop_height']

    for observations in ([None]*90, [[478,864,823,1010]]*90):
        hold = compose_portrait(observations, [[hoop]]*90, 2688, 1512, 7)
        assert (hold['crop_width'], hold['crop_height'], hold['crop_y']) == (850, 1512, 0)
        assert hold['centers'] == pytest.approx([1000] * 90, rel=0, abs=1e-9)
        assert hold['filter'].startswith('crop=850:1512')
    sparse = [None] * 90
    sparse[-2:] = [[1200, 600, 1220, 620]] * 2
    assert compose_portrait(sparse, [], 1920, 1080, 7)['sources'] == ['hoop'] * 90
    assert compose_portrait([None]*90, [], 1920, 1080, 7)['centers'] == [960] * 90


def test_portrait_merge_keeps_shot_times_from_all_candidates():
    source = dict(source_path='court.mp4', review_start_ms=0, review_end_ms=2000,
                  event_time_ms=500, manual=True)
    clips = [source, dict(source, manual=False, event_time_ms=1900),
             dict(source, manual=False, review_start_ms=1500, review_end_ms=4000,
                  event_time_ms=3200)]
    [merged] = export.merge_overlapping_candidates(clips, keep_portrait_events=True)
    assert merged['portrait_events_ms'] == [1900, 3200]



def test_tracker_uses_source_timestamps_for_variable_frame_rate(monkeypatch):
    import cv2
    from basketball_highlight.onnx_detector import Result

    timestamps = [1., 1.04, 1.08, 1.12, 1.19, 1.28, 1.31]

    class Capture:
        index = -1

        def isOpened(self): return True
        def set(self, *args): pass
        def release(self): pass
        def get(self, key):
            if key == cv2.CAP_PROP_POS_MSEC:
                return timestamps[self.index] * 1000
            return {cv2.CAP_PROP_FRAME_WIDTH: 1920, cv2.CAP_PROP_FRAME_HEIGHT: 1080,
                    cv2.CAP_PROP_FPS: 30}[key]
        def grab(self):
            self.index += 1
            return self.index < len(timestamps)
        def retrieve(self): return True, self.index
        def read(self): return self.grab(), self.index

    frames = []

    class Model:
        def predict(self, frame, **kwargs):
            frames.append(frame)
            return [Result([], {})]

    monkeypatch.setattr(cv2, 'VideoCapture', lambda *args: Capture())
    tracker = PortraitTracker.__new__(PortraitTracker)
    tracker.model = Model()
    tracker.device = 'cpu'
    tracker.track(dict(source_path='source.mp4', review_start_ms=1000, review_end_ms=1400))
    assert frames == [0, 3, 4, 6]



def test_person_model_requires_an_existing_local_file(monkeypatch,tmp_path):
    from basketball_highlight import inference

    ball = tmp_path/'bball_model.pt'
    person = tmp_path/'local'/'yolo11n.pt'
    calls = []

    def load(path, device=None):
        calls.append((path,device))
        return object()

    monkeypatch.setattr(inference,'load_detector',load)
    monkeypatch.setattr(inference,'select_device',lambda *a: 'cpu')
    monkeypatch.setattr(inference,'current_device',lambda: 'cpu')
    monkeypatch.delenv('BHE_PORTRAIT_PERSON_MODEL',raising=False)
    assert PortraitTracker(ball).person_model is None
    assert calls == [(ball,None)]
    person.parent.mkdir()
    person.touch()
    assert PortraitTracker(ball).person_model is not None
    assert calls[-2:] == [(ball,None),(person,'cpu')]
    monkeypatch.setenv('BHE_PORTRAIT_PERSON_MODEL',str(tmp_path/'missing.pt'))
    assert PortraitTracker(ball).person_model is None


def test_crossings_choose_sustained_real_rim_and_guard_without_a_confirmed_goal():
    decoy = [410, 280, 458, 320]
    rim = [1475, 400, 1525, 450]
    brief = [970, 400, 1020, 450]
    rims = [[decoy, rim] if i % 3 == 0 else [decoy]*3 for i in range(75)]
    rims[20].extend([brief]*50)
    false_ball = [610, 310, 630, 330]
    balls = [false_ball]*75
    local = [[] for _ in balls]
    for i, y in [(18, 387), (20, 414), (22, 446)]:
        local[i] = [[1490, y-10, 1510, y+10]]
    players = [[500, 530, 555, 690], [620, 550, 680, 710]]
    plan = compose_portrait(balls,rims,1920,1080,[],people=[players]*75,local_balls=local)
    assert plan['rim'] == rim
    assert plan['crossings'] == [2.]
    assert all(plan['guarded'][5:41])
    assert all(abs(x-1500) <= plan['crop_width']/2-25 for x in plan['centers'][5:41])
    assert plan['sources'][23:43] == ['hoop']*20


def test_missing_ball_after_close_approach_holds_rim_before_crowd_even_without_crossing():
    rim = [1475, 400, 1525, 450]
    close = [1480, 360, 1500, 380]
    balls = [None]*20 + [close]*12 + [None]*48
    players = [[500, 530, 555, 690], [620, 550, 680, 710]]
    plan = compose_portrait(balls,[[rim]]*80,1920,1080,[],people=[players]*80)
    assert plan['crossings'] == []
    assert plan['sources'][32:52] == ['hoop']*20
    assert plan['sources'][52] == 'crowd'
    w = plan['crop_width']
    centers = plan['centers'][52:]
    assert max(abs(a-b)*SAMPLE_FPS/w for a,b in zip(centers,centers[1:])) <= .602
    assert max(abs(a-2*b+c)*SAMPLE_FPS**2/w
               for a,b,c in zip(centers,centers[1:],centers[2:])) <= .803


def test_tail_extrapolates_from_recent_track_instead_of_falling_back_to_hoop():
    rim = [920, 575, 970, 625]
    balls = [_ball(650+15*i) for i in range(42)] + [None]*14
    plan = compose_portrait(balls,[[rim]]*len(balls),1920,1080,[])
    assert plan['sources'][-1] == 'tail'
    assert plan['centers'][-1] > plan['centers'][41]+100
