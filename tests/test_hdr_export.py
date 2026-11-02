from pathlib import Path
import json
import subprocess
import sys

import pytest

from engine.python.basketball_engine.adapters import hdr, export


@pytest.fixture
def bt2020():
    return {'pix_fmt': 'yuv420p10le', 'color_transfer': 'smpte2084',
            'color_primaries': 'bt2020', 'color_space': 'bt2020nc', 'side_data_list': []}


@pytest.mark.parametrize('transfer', ['smpte2084', 'arib-std-b67'])
def test_10bit_hdr_maps_only_with_filters(bt2020, monkeypatch, transfer):
    bt2020['color_transfer'] = transfer
    monkeypatch.setattr(hdr, 'hdr_filter_available', lambda: True)
    assert hdr.color_plan(bt2020) == (True, None)
    monkeypatch.setattr(hdr, 'hdr_filter_available', lambda: False)
    assert hdr.color_plan(bt2020) == (False, hdr.HDR_UNAVAILABLE)


@pytest.mark.parametrize('update,warning', [
    ({'pix_fmt': 'yuv420p'}, hdr.HDR_UNKNOWN),
    ({'color_transfer': None}, hdr.HDR_UNKNOWN),
    ({'color_primaries': None}, hdr.HDR_UNKNOWN),
    ({'color_space': 'bt709'}, hdr.HDR_UNKNOWN),
    ({'color_transfer': 'bt709'}, None),
    ({'color_transfer': 'smpte2084', 'side_data_list': [{'side_data_type': 'DOVI configuration record', 'dv_profile': 5}]}, hdr.HDR_UNKNOWN),
    ({'color_transfer': 'smpte2084', 'side_data_list': [{'side_data_type': 'DOVI configuration record', 'dv_profile': 8}]}, hdr.HDR_UNKNOWN),
    ({'color_transfer': 'arib-std-b67', 'side_data_list': [{'side_data_type': 'DOVI configuration record', 'dv_profile': 8, 'dv_bl_signal_compatibility_id': 1}]}, hdr.HDR_UNKNOWN),
    ({'color_transfer': 'smpte2084', 'side_data_list': [{'side_data_type': 'DOVI configuration record', 'dv_profile': 8, 'dv_bl_signal_compatibility_id': 1}]}, None),
    ({'color_transfer': 'arib-std-b67', 'side_data_list': [{'side_data_type': 'DOVI configuration record', 'dv_profile': 8, 'dv_bl_signal_compatibility_id': 4}]}, None),
])
def test_uncertain_and_dolby_inputs_are_conservative(bt2020, monkeypatch, update, warning):
    monkeypatch.setattr(hdr, 'hdr_filter_available', lambda: True)
    bt2020.update(update)
    enabled, actual_warning = hdr.color_plan(bt2020)
    assert actual_warning == warning
    assert enabled == (warning is None and bt2020['color_transfer'] in hdr.HDR_TRANSFERS)


def test_sdr_command_snapshot_unchanged(monkeypatch):
    monkeypatch.setattr(export, 'resolve_media_tool', lambda name: name)
    assert export.build_clip_command(Path('input.mp4'), 1000, 3000, Path('output.mp4'),
                                     'mpeg4', has_audio=False) == [
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-ss', '1.000', '-i', 'input.mp4',
        '-t', '2.000', '-map', '0:v:0?', '-an', '-c:v', 'mpeg4', '-q:v', '2',
        '-movflags', '+faststart', 'output.mp4']
    assert export.build_clip_command(Path('input.mp4'), 1000, 3000, Path('output.mp4'),
        'mpeg4', frame_size=(640,360), has_audio=False)[14:16] == [
        '-vf', 'scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2,setsar=1']


def test_hdr_filter_precedes_resize_and_sets_tags(monkeypatch):
    monkeypatch.setattr(export, 'resolve_media_tool', lambda name: name)
    cmd = export.build_clip_command(Path('source'), 0, 1000, Path('out.mp4'),
                                    'mpeg4', frame_size=(640,360), tonemap=True, has_audio=False)
    vf = cmd[cmd.index('-vf') + 1]
    assert vf.startswith(hdr.TONEMAP_FILTER + ',scale=')
    assert cmd[cmd.index('-color_trc') + 1] == 'bt709'


@pytest.mark.parametrize('effect', ['approach', 'replay'])
def test_effect_all_video_branches_use_tonemap(effect, monkeypatch):
    monkeypatch.setattr(export, 'resolve_media_tool', lambda name: name)
    candidate = {'event_time_ms': 2000, 'review_start_ms': 0, 'review_end_ms': 4000,
                 'width':640,'height':360,'fps':15,'has_audio':False,
                 'rim': {'x':320,'y':180,'width':60}, 'trail': []}
    spec=export.effect_spec(candidate, effect)
    assert spec
    cmd=export.build_clip_command(Path('source'),0,4000,Path('out.mp4'),'mpeg4',effect=spec,tonemap=True,has_audio=False)
    graph=cmd[cmd.index('-filter_complex')+1]
    assert graph.count('tonemap=tonemap=hable') == graph.count('[0:v:0]') + graph.count('[1:v:0]')
    assert cmd[cmd.index('-color_trc')+1]=='bt709'


def test_capability_check_cached_and_missing_filter_is_safe(monkeypatch):
    seen=[]
    def run(cmd, **kwargs):
        seen.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout=' .S zscale V->V\n .S tonemap V->V\n')
    hdr._filters_available.cache_clear();monkeypatch.setattr(hdr.subprocess,'run',run)
    assert hdr._filters_available('fake') and hdr._filters_available('fake')
    assert len(seen)==1
    hdr._filters_available.cache_clear()
    monkeypatch.setattr(hdr.subprocess,'run',lambda *a,**k: subprocess.CompletedProcess(a, 0, stdout=' .S zscale V->V\n'))
    assert not hdr._filters_available('missing')
    hdr._filters_available.cache_clear()


def test_mixed_incompatible_streams_force_reencode_without_second_tonemap(monkeypatch,tmp_path):
    monkeypatch.setattr(export, '_audio_layouts', lambda paths: [None] * len(paths))
    calls=[]
    monkeypatch.setattr(export, '_compatible_color_streams', lambda paths: False)
    monkeypatch.setattr(export, 'video_codecs', lambda: ['mpeg4'])
    def run(command, output_path, **kwargs):
        calls.append(command);output_path.parent.mkdir(parents=True,exist_ok=True);output_path.write_bytes(b'fake')
    monkeypatch.setattr(export, 'run_atomic_ffmpeg', run)
    candidates=[{'source_path':str(tmp_path/'a'),'event_time_ms':500,'review_start_ms':0,'review_end_ms':1000,'tonemap':True},
                {'source_path':str(tmp_path/'b'),'event_time_ms':1500,'review_start_ms':1000,'review_end_ms':2000,'tonemap':False}]
    export.export_goal_clips(candidates,tmp_path/'out','merge')
    assert any('tonemap=tonemap=hable' in arg for arg in calls[0])
    assert not any('tonemap=tonemap=hable' in arg for arg in calls[1])
    assert '-c' not in calls[-1] and '-c:v' in calls[-1]
    assert not any('tonemap=tonemap=hable' in arg for arg in calls[-1])


def test_encoder_fallback_retains_tonemap(monkeypatch, tmp_path):
    attempts = []
    monkeypatch.setattr(export, 'video_codecs', lambda: ['h264_nvenc', 'mpeg4'])
    def run(command, output_path, **kwargs):
        attempts.append(command)
        if len(attempts) == 1:
            raise subprocess.CalledProcessError(1, command)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(b'ok')
    monkeypatch.setattr(export, 'run_atomic_ffmpeg', run)
    candidate = {'source_path': str(tmp_path/'input'), 'event_time_ms': 500,
                 'review_start_ms': 0, 'review_end_ms': 1000, 'tonemap': True}
    export.export_goal_clips([candidate], tmp_path/'out', 'separate')
    assert len(attempts) == 2
    assert all(hdr.TONEMAP_FILTER in command[command.index('-vf') + 1] for command in attempts)
    assert all(command[command.index('-color_trc') + 1] == 'bt709' for command in attempts)


def test_missing_metadata_warns():
    assert hdr.color_plan({}) == (False, hdr.HDR_UNKNOWN)

@pytest.mark.parametrize('second_range,compatible', [('tv', True), ('pc', False), (None, False)])
def test_compatible_color_streams_requires_matching_known_range(monkeypatch, second_range, compatible):
    stream = {'codec_name': 'h264', 'pix_fmt': 'yuv420p', 'width': 64, 'height': 64,
              'color_space': 'bt709', 'color_transfer': 'bt709', 'color_primaries': 'bt709'}
    ranges = iter(['tv', second_range])
    def probe(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps({'streams': [{**stream, 'color_range': next(ranges)}]}))
    monkeypatch.setattr(export.subprocess, 'run', probe)
    assert export._compatible_color_streams([Path('a'), Path('b')]) is compatible


@pytest.mark.parametrize('reverse', [False, True])
def test_real_mixed_ranges_are_normalized(monkeypatch, tmp_path, reverse):
    ffmpeg = export.resolve_media_tool('ffmpeg')
    ffprobe = export.resolve_media_tool('ffprobe')
    if not hdr.hdr_filter_available():
        pytest.skip('zscale and tonemap are unavailable')
    def run(args):
        return subprocess.run(args, check=True, capture_output=True)
    source = tmp_path / 'hdr.mkv'
    full = tmp_path / 'full.mp4'
    run([ffmpeg, '-y', '-v', 'error', '-f', 'lavfi', '-i',
         'color=black:s=64x64:r=5:d=1,drawbox=x=32:y=0:w=32:h=64:color=white:t=fill',
         '-vf', 'zscale=matrixin=709:transferin=709:primariesin=709:matrix=2020_ncl:transfer=arib-std-b67:primaries=2020,format=yuv420p10le',
         '-c:v', 'ffv1', '-color_primaries', 'bt2020', '-color_trc', 'arib-std-b67',
         '-colorspace', 'bt2020nc', str(source)])
    run([ffmpeg, '-y', '-v', 'error', '-i', str(source), '-vf',
         hdr.TONEMAP_FILTER + ',scale=in_range=tv:out_range=pc,format=yuvj420p',
         '-c:v', 'mpeg4', '-q:v', '2', '-color_range', 'pc', '-color_primaries', 'bt709',
         '-color_trc', 'bt709', '-colorspace', 'bt709', str(full)])
    limited = tmp_path / 'limited.mp4'
    run([ffmpeg, '-y', '-v', 'error', '-i', str(source), '-vf', hdr.TONEMAP_FILTER,
         '-c:v', 'mpeg4', '-q:v', '2', *hdr.SDR_TAGS, str(limited)])
    assert not export._compatible_color_streams([limited, full])
    monkeypatch.setattr(export, 'video_codecs', lambda: ['mpeg4'])
    build = export.build_clip_command
    def preserve_full_range(*args, **kwargs):
        cmd = build(*args, **kwargs)
        if args[0] == full:
            pos = cmd.index('-c:v')
            cmd[pos:pos] = ['-vf', 'scale=in_range=auto:out_range=pc,format=yuvj420p']
            cmd[-1:-1] = ['-color_range', 'pc']
        return cmd
    monkeypatch.setattr(export, 'build_clip_command', preserve_full_range)
    candidates = [
        {'source_path': str(source), 'event_time_ms': 500, 'review_start_ms': 0,
         'review_end_ms': 1000, 'width': 64, 'height': 64, 'has_audio': False, 'tonemap': True},
        {'source_path': str(full), 'event_time_ms': 500, 'review_start_ms': 0,
         'review_end_ms': 1000, 'width': 64, 'height': 64, 'has_audio': False, 'tonemap': False},
    ]
    if reverse:
        candidates.reverse()
    result = export.export_goal_clips(candidates, tmp_path / 'out', 'merge')
    assert not export._compatible_color_streams([Path(p) for p in result['clip_files']])
    output = result['files'][0]
    metadata = json.loads(run([ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=color_range,color_space,color_transfer,color_primaries',
        '-of', 'json', output]).stdout)['streams'][0]
    assert metadata == {'color_range': 'tv', 'color_space': 'bt709',
                        'color_transfer': 'bt709', 'color_primaries': 'bt709'}
    def levels(at):
        raw = run([ffmpeg, '-v', 'error', '-ss', str(at), '-i', output,
                   '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']).stdout
        def pixel(x, y):
            offset = (y * 64 + x) * 3
            return sum(raw[offset:offset + 3]) / 3
        return pixel(16, 32), pixel(48, 32)
    first, second = levels(.4), levels(1.4)
    assert abs(first[0] - second[0]) <= 8
    assert abs(first[1] - second[1]) <= 8
    assert first[0] < 25 and first[1] > 150


def test_real_untagged_sdr_merge_uses_copy_without_color_temp(tmp_path):
    ffmpeg = export.resolve_media_tool('ffmpeg')
    ffprobe = export.resolve_media_tool('ffprobe')
    source = tmp_path / 'sdr.mp4'
    subprocess.run([ffmpeg, '-y', '-v', 'error', '-f', 'lavfi', '-i',
                    'testsrc2=size=64x64:rate=5:duration=3', '-c:v', 'mpeg4',
                    '-q:v', '2', str(source)], check=True, capture_output=True)
    candidates = [
        {'source_path': str(source), 'event_time_ms': 500, 'review_start_ms': 0,
         'review_end_ms': 1000, 'width': 64, 'height': 64, 'has_audio': False},
        {'source_path': str(source), 'event_time_ms': 2500, 'review_start_ms': 2000,
         'review_end_ms': 3000, 'width': 64, 'height': 64, 'has_audio': False},
    ]
    commands, temporary_prefixes = [], []
    previous_profile = sys.getprofile()
    def observe(frame, event, arg):
        if event == 'call' and frame.f_code is export.run_atomic_ffmpeg.__code__:
            commands.append(list(frame.f_locals['command']))
        if event == 'call' and frame.f_code is export.tempfile.TemporaryDirectory.__init__.__code__:
            temporary_prefixes.append(frame.f_locals.get('prefix'))
        return observe
    try:
        sys.setprofile(observe)
        result = export.export_goal_clips(candidates, tmp_path / 'out', 'merge')
    finally:
        sys.setprofile(previous_profile)
    assert Path(result['files'][0]).is_file()
    assert len(result['clip_files']) == 2
    for path in result['clip_files']:
        data = subprocess.run([ffprobe, '-v', 'error', '-select_streams', 'v:0',
            '-show_entries', 'stream=color_range,color_space,color_transfer,color_primaries',
            '-of', 'json', path], capture_output=True, check=True)
        fields = json.loads(data.stdout)['streams'][0]
        assert all(fields.get(key) in (None, 'unknown', 'unspecified')
                   for key in ('color_range', 'color_space', 'color_transfer', 'color_primaries'))
    assert commands[-1][-3:-1] == ['-c', 'copy']
    assert not any('bhe-color-' in str(prefix) for prefix in temporary_prefixes)
    assert not list((tmp_path / 'out').glob('bhe-color-*'))
