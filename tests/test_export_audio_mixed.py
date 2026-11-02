import json
import subprocess
from pathlib import Path

import pytest

from engine.python.basketball_engine.adapters import export


def _make(path, rate=None, channels=2):
    cmd = ['ffmpeg','-y','-v','error','-f','lavfi','-i','testsrc2=size=64x64:rate=25:duration=1']
    if rate:
        cmd += ['-f','lavfi','-i',f'sine=frequency=440:sample_rate={rate}:duration=1', '-ac',str(channels),'-c:a','aac']
    cmd += ['-c:v','mpeg4','-q:v','2',str(path)]
    subprocess.run(cmd, check=True, capture_output=True)


@pytest.mark.parametrize('layouts', [[None, (48000,2)], [(48000,2), None], [(48000,2),(44100,1)]])
def test_mixed_audio_layouts_are_normalized(tmp_path, monkeypatch, layouts):
    monkeypatch.setattr(export, 'video_codecs', lambda: ['mpeg4'])
    candidates=[]
    for i, layout in enumerate(layouts):
        path=tmp_path/f'source{i}.mp4'
        _make(path, *(layout or (None,)))
        candidates.append({'source_path':str(path),'event_time_ms':500,'review_start_ms':0,
                           'review_end_ms':1000,'width':64,'height':64,'fps':25,'has_audio':layout is not None})
    result=export.export_goal_clips(candidates,tmp_path/'out','merge')
    data=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_entries',
         'stream=codec_type,duration,sample_rate,channels','-of','json',result['files'][0]]))
    streams={s['codec_type']:s for s in data['streams']}
    assert streams['audio']['sample_rate']=='48000' and streams['audio']['channels']==2
    assert float(streams['audio']['duration']) == pytest.approx(2, abs=.1)
    assert float(streams['video']['duration']) == pytest.approx(2, abs=.1)


def test_same_audio_uses_stream_copy_fast_path(tmp_path, monkeypatch):
    monkeypatch.setattr(export, 'video_codecs', lambda: ['mpeg4'])
    commands=[]
    original=export.run_atomic_ffmpeg
    def record(command, output_path, **kwargs):
        commands.append(command)
        return original(command, output_path, **kwargs)
    monkeypatch.setattr(export, 'run_atomic_ffmpeg', record)
    candidates=[]
    for i in range(2):
        path=tmp_path/f'source{i}.mp4'
        _make(path, 48000, 2)
        candidates.append({'source_path':str(path),'event_time_ms':500,'review_start_ms':0,
                           'review_end_ms':1000,'width':64,'height':64,'fps':25,'has_audio':True})
    result=export.export_goal_clips(candidates,tmp_path/'out','merge')
    assert len(commands)==3
    assert commands[-1][-3:-1]==['-c','copy']
    assert Path(result['files'][0]).is_file()


def test_duration_probe_failure_or_missing_stream_fails(tmp_path, monkeypatch):
    path=tmp_path/'output.mp4'
    def failed(*args, **kwargs): raise subprocess.TimeoutExpired('ffprobe', 15)
    monkeypatch.setattr(export.subprocess, 'run', failed)
    assert not export._merged_duration_ok(path, 1000, require_audio=True)
    def no_audio(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps({'streams':[{'codec_type':'video','duration':'1.0'}]}))
    monkeypatch.setattr(export.subprocess, 'run', no_audio)
    assert not export._merged_duration_ok(path, 1000, require_audio=True)


def test_frame_rate_probe_failure_is_not_silently_accepted(monkeypatch):
    def failed(*args, **kwargs): raise subprocess.TimeoutExpired('ffprobe', 15)
    monkeypatch.setattr(export.subprocess, 'run', failed)
    with pytest.raises(OSError, match='帧率'):
        export._uniform_frame_rate([Path('clip.mp4')])


def test_reencoded_output_is_checked_again(tmp_path, monkeypatch):
    monkeypatch.setattr(export, 'video_codecs', lambda: ['mpeg4'])
    monkeypatch.setattr(export, '_audio_layouts', lambda paths: [None] * len(paths))
    monkeypatch.setattr(export, '_uniform_frame_rate', lambda paths: None)
    checks=[]
    def invalid(*args, **kwargs):
        checks.append(args[0])
        return False
    monkeypatch.setattr(export, '_merged_duration_ok', invalid)
    def fake(command, output_path, **kwargs): output_path.write_bytes(b'video')
    monkeypatch.setattr(export, 'run_atomic_ffmpeg', fake)
    candidates=[{'source_path':'a.mp4','event_time_ms':500,'review_start_ms':0,'review_end_ms':1000}]
    with pytest.raises(OSError, match='时长校验失败'):
        export.export_goal_clips(candidates,tmp_path/'out','merge')
    assert len(checks)==2
    assert not (tmp_path/'out'/'highlights.mp4').exists()


def test_variable_frame_rate_requires_normalization(tmp_path):
    path=tmp_path/'vfr.mp4'
    subprocess.run(['ffmpeg','-y','-v','error','-f','lavfi','-i','testsrc2=size=64x64:rate=30:duration=2',
                    '-vf',"select='not(mod(n,3))+not(mod(n,7))'",'-fps_mode','vfr',
                    '-c:v','mpeg4',str(path)],check=True,capture_output=True)
    assert export._uniform_frame_rate([path]) is not None
