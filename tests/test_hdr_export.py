from pathlib import Path
import json
import subprocess

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
