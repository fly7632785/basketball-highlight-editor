import json
from fractions import Fraction
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


def test_same_audio_uses_video_stream_copy(tmp_path, monkeypatch):
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
    assert commands[-1][commands[-1].index('-c:v') + 1] == 'copy'
    assert commands[-1][commands[-1].index('-c:a') + 1] == 'aac'
    assert Path(result['files'][0]).is_file()


def test_bad_merged_packets_do_not_replace_existing_target(tmp_path, monkeypatch):
    destination = tmp_path / 'highlights.mp4'
    destination.write_bytes(b'previous')
    def probe(path):
        points = (Fraction(0),) if path.name.startswith('goal_') else (Fraction(0), Fraction(1, 2))
        return export.MergeClip(path, ('mpeg4',), points, Fraction(1), None, True)
    monkeypatch.setattr(export, '_probe_merge_clip', probe)
    def fake(command, output_path, **kwargs):
        if 'validate_output' in kwargs:
            kwargs['validate_output'](tmp_path / 'unpublished.mp4')
        output_path.write_bytes(b'video')
    monkeypatch.setattr(export, 'run_atomic_ffmpeg', fake)
    candidates = [{'source_path': 'a.mp4', 'event_time_ms': 500, 'review_start_ms': 0, 'review_end_ms': 1000}]
    with pytest.raises(OSError, match='时长校验失败'):
        export.export_goal_clips(candidates, tmp_path / 'out', 'merge', destination)
    assert destination.read_bytes() == b'previous'


def test_variable_frame_rate_is_preserved_inside_segments(tmp_path):
    path = tmp_path / 'vfr.mp4'
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x64:rate=30:duration=2',
                    '-vf', "select='not(between(n,9,15))'", '-fps_mode', 'vfr',
                    '-c:v', 'mpeg4', str(path)], check=True, capture_output=True)
    candidates = [{'source_path': str(path), 'event_time_ms': 1000, 'review_start_ms': 0,
                   'review_end_ms': 2000, 'has_audio': False}]
    result = export.export_goal_clips(candidates, tmp_path / 'out', 'merge')
    source = export._probe_merge_clip(path)
    output = export._probe_merge_clip(Path(result['files'][0]))
    assert source.pts == output.pts
