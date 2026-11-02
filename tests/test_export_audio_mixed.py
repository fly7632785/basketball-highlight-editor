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
