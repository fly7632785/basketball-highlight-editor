import json
import subprocess
from fractions import Fraction

import pytest

from engine.python.basketball_engine.adapters import export
from tests.test_export_adapter import _ffmpeg_or_skip, _fps_source


def _packets(path):
    _, ffprobe = _ffmpeg_or_skip()
    data = json.loads(subprocess.check_output([
        ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=time_base:packet=pts,duration,flags', '-of', 'json', str(path),
    ]))
    base = Fraction(data['streams'][0]['time_base'])
    return sorted((int(packet['pts']) * base, int(packet['duration']) * base)
                  for packet in data['packets'] if 'D' not in packet['flags'])


def _candidate(path, fps):
    return dict(source_path=str(path), review_start_ms=0, review_end_ms=2000,
                event_time_ms=1000, fps=fps, has_audio=True)


def test_merge_uses_video_end_at_seam_with_longer_audio(tmp_path):
    ffmpeg, _ = _ffmpeg_or_skip()
    paths = [tmp_path / f'{index}.mp4' for index in range(2)]
    for path, length in zip(paths, ('1.75', '2')):
        subprocess.run([
            ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', f'testsrc2=s=320x180:r=30:d={length}',
            '-f', 'lavfi', '-i', 'sine=r=48000:d=2', '-c:v', 'libx264', '-c:a', 'aac', str(path),
        ], check=True)
    result = export.export_goal_clips([_candidate(path, 30) for path in paths], tmp_path / 'out', 'merge')
    packets = _packets(result['files'][0])
    assert len(packets) == 113
    assert all(abs(right - left - Fraction(1, 30)) < Fraction(1, 60000)
               for (left, _), (right, _) in zip(packets, packets[1:]))


@pytest.mark.parametrize('rates,expected_counts', [
    (('30', '60'), (120, 120)),
    (('60000/1001', '60'), (120, 120)),
])
def test_merge_frame_rate_preserves_high_rate_clips(tmp_path, rates, expected_counts):
    candidates = [_candidate(_fps_source(tmp_path, f'source{index}', rate, 60000), float(Fraction(rate)))
                  for index, rate in enumerate(rates)]
    result = export.export_goal_clips(candidates, tmp_path / 'out', 'merge')
    assert tuple(len(_packets(path)) for path in result['clip_files']) == expected_counts
    if rates[0] != '30':
        packets = _packets(result['files'][0])
        assert {duration for _, duration in packets} >= {Fraction(1, 60), Fraction(1001, 60000)}
