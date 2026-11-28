import json
import subprocess
import sys
import threading
import time
from fractions import Fraction

import pytest

from engine.python.basketball_engine.adapters import export
from tests.test_export_adapter import _ffmpeg_or_skip, _fps_source


def _packet_pts(path):
    _, ffprobe = _ffmpeg_or_skip()
    data = json.loads(subprocess.check_output([
        ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=time_base:packet=pts,flags', '-of', 'json', str(path),
    ]))
    base = Fraction(data['streams'][0]['time_base'])
    return sorted(int(packet['pts']) * base
                  for packet in data['packets'] if 'D' not in packet['flags'])


def _candidate(path, fps):
    return dict(source_path=str(path), review_start_ms=0, review_end_ms=2000,
                event_time_ms=1000, fps=fps, has_audio=True)


@pytest.mark.parametrize('stream_end, expected_end', [(280, 280), (250, 290)])
def test_merge_probe_recovers_missing_last_duration(tmp_path, monkeypatch, stream_end, expected_end):
    data = {
        'streams': [{'index': 0, 'codec_type': 'video', 'time_base': '1/1000',
                     'start_pts': 100, 'duration_ts': stream_end - 100}],
        'packets': [
            {'stream_index': 0, 'pts': 90, 'flags': 'KD_'},
            {'stream_index': 0, 'pts': 100, 'flags': 'K__'},
            {'stream_index': 0, 'pts': 250, 'flags': '___'},
            {'stream_index': 0, 'pts': 140, 'duration': 70, 'flags': '___'},
            {'stream_index': 0, 'pts': 210, 'duration': 40, 'flags': '___'},
        ],
    }
    monkeypatch.setattr(export, '_run_export_probe', lambda *args, **kwargs: json.dumps(data))
    clip = export._probe_merge_clip(tmp_path / 'clip.mp4')
    assert clip.pts == tuple(Fraction(pts, 1000) for pts in (100, 140, 210, 250))
    assert clip.end == Fraction(expected_end, 1000)


def test_merge_uses_video_end_at_seam_with_longer_audio(tmp_path):
    ffmpeg, _ = _ffmpeg_or_skip()
    paths = [tmp_path / f'{index}.mp4' for index in range(2)]
    for path, length in zip(paths, ('1.75', '2')):
        subprocess.run([
            ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', f'testsrc2=s=320x180:r=30:d={length}',
            '-f', 'lavfi', '-i', 'sine=r=48000:d=2', '-c:v', 'libx264', '-c:a', 'aac', str(path),
        ], check=True)
    result = export.export_goal_clips([_candidate(path, 30) for path in paths], tmp_path / 'out', 'merge')
    pts = _packet_pts(result['files'][0])
    assert len(pts) == 113
    assert all(abs(right - left - Fraction(1, 30)) < Fraction(1, 60000)
               for left, right in zip(pts, pts[1:]))


@pytest.mark.parametrize('rates,expected_counts', [
    (('30', '60'), (120, 120)),
    (('60000/1001', '60'), (120, 120)),
])
def test_merge_frame_rate_preserves_high_rate_clips(tmp_path, rates, expected_counts):
    candidates = [_candidate(_fps_source(tmp_path, f'source{index}', rate, 60000), float(Fraction(rate)))
                  for index, rate in enumerate(rates)]
    result = export.export_goal_clips(candidates, tmp_path / 'out', 'merge')
    assert tuple(len(_packet_pts(path)) for path in result['clip_files']) == expected_counts
    if rates[0] != '30':
        pts = _packet_pts(result['files'][0])
        first_clip_intervals = [right - left for left, right in zip(pts[:120], pts[1:121])]
        final_clip_intervals = [right - left for left, right in zip(pts[120:], pts[121:])]
        assert first_clip_intervals == [Fraction(1001, 60000)] * 120
        assert final_clip_intervals == [Fraction(1, 60)] * 119


@pytest.mark.parametrize('ratios', [('1/1', '4/3'), ('4/3', '1/1')])
def test_merge_preserves_display_geometry_across_different_sample_aspect_ratios(tmp_path, monkeypatch, ratios):
    ffmpeg, ffprobe = _ffmpeg_or_skip()
    monkeypatch.setattr(export, 'video_codecs', lambda: ['libx264'])
    candidates = []
    for index, ratio in enumerate(ratios):
        path = tmp_path / f'clip{index}.mp4'
        subprocess.run([
            ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'color=white:s=160x90:r=30:d=2',
            '-vf', f'setsar={ratio}', '-c:v', 'libx264', str(path),
        ], check=True)
        candidates.append({**_candidate(path, 30), 'has_audio': False})
    result = export.export_goal_clips(candidates, tmp_path / 'out', 'merge')
    output = result['files'][0]
    info = json.loads(subprocess.check_output([
        ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height,sample_aspect_ratio', '-of', 'json', output,
    ]))
    assert info['streams'] == [{'width': 160, 'height': 90, 'sample_aspect_ratio': '1:1'}]
    assert len(_packet_pts(output)) == 120
    for index, ratio in enumerate(ratios):
        pixels = subprocess.check_output([
            ffmpeg, '-v', 'error', '-ss', str(.5 + 2 * index), '-i', output,
            '-frames:v', '1', '-pix_fmt', 'gray', '-f', 'rawvideo', '-',
        ])
        assert pixels[45 * 160 + 80] > 200
        assert (pixels[80] < 32) == (ratio == '4/3')  # Anamorphic input needs letterboxing.


def _fractional_part(tmp_path):
    ffmpeg, _ = _ffmpeg_or_skip()
    path = tmp_path / 'part.mp4'
    subprocess.run([
        ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=160x90:r=30000/1001',
        '-frames:v', '31', '-c:v', 'libx264', '-video_track_timescale', '60000', str(path),
    ], check=True)
    return path


def test_many_fractional_clips_keep_all_video_packets(tmp_path):
    part = _fractional_part(tmp_path)
    output = tmp_path / 'merged.mp4'
    export._merge_encoded_clips([part] * 90, output, ['libx264'], False, None, None)
    pts = _packet_pts(output)
    assert len(pts) == 90 * 31
    assert all(abs(right - left - Fraction(1001, 30000)) <= Fraction(1, 60000)
               for left, right in zip(pts, pts[1:]))


def test_invalid_copy_is_encoded_with_the_same_timeline(tmp_path, monkeypatch):
    from dataclasses import replace

    part = _fractional_part(tmp_path)
    output = tmp_path / 'merged.mp4'
    run = export.run_atomic_ffmpeg
    probe = export._probe_merge_clip
    attempts = []

    def record(command, destination, **kwargs):
        attempts.append(command[command.index('-c:v') + 1])
        return run(command, destination, **kwargs)

    def corrupt_copy_metadata(path, **kwargs):
        clip = probe(path, **kwargs)
        if path.name.startswith('.merged.') and attempts[-1] == 'copy':
            return replace(clip, pts=clip.pts[:-1])
        return clip

    monkeypatch.setattr(export, 'run_atomic_ffmpeg', record)
    monkeypatch.setattr(export, '_probe_merge_clip', corrupt_copy_metadata)
    export._merge_encoded_clips([part] * 2, output, ['libx264'], False, None, None)
    assert attempts == ['copy', 'libx264']
    assert len(_packet_pts(output)) == 62


def test_cancel_interrupts_running_packet_probe(tmp_path, monkeypatch):
    part = _fractional_part(tmp_path)
    output = tmp_path / 'merged.mp4'
    output.write_bytes(b'existing')
    cancelled = threading.Event()
    popen = subprocess.Popen
    probes = []

    def slow_probe(command, **kwargs):
        if any('packet=stream_index,pts' in arg for arg in command):
            with popen(command, stdout=subprocess.PIPE, text=True) as probe:
                stream_info, _ = probe.communicate()
                assert probe.returncode == 0
            process = popen([sys.executable, '-c', 'import sys, time; time.sleep(2); print(sys.argv[1])',
                             stream_info], **kwargs)
            probes.append(process)
            cancelled.set()
            return process
        return popen(command, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(subprocess, 'Popen', slow_probe)
        start = time.monotonic()
        with pytest.raises(export.PipelineCancelled):
            export._merge_encoded_clips([part], output, ['libx264'], False, cancelled.is_set, None)
        assert time.monotonic() - start < 1.5
    assert probes and probes[0].poll() is not None
    assert output.read_bytes() == b'existing'


def test_cancel_in_validation_preserves_existing_destination(tmp_path, monkeypatch):
    output = tmp_path / 'merged.mp4'
    output.write_bytes(b'existing')
    cancelled = threading.Event()
    monkeypatch.setattr(export, 'validate_media_file', lambda path, **kwargs: None)
    command = [sys.executable, '-c', 'import sys; open(sys.argv[-1], "wb").write(b"new")', str(output)]

    with pytest.raises(export.PipelineCancelled):
        export.run_atomic_ffmpeg(command, output, cancel_check=cancelled.is_set,
                                 validate_output=lambda path: cancelled.set())
    assert output.read_bytes() == b'existing'
    assert set(tmp_path.iterdir()) == {output}
