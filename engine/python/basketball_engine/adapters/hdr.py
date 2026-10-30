"""Conservative HDR detection and capabilities for the bundled FFmpeg."""
from __future__ import annotations

import re
import subprocess
from functools import lru_cache
from pathlib import Path
from typing import Any

from ..diagnostics import log_diagnostic
from ..media_tools import resolve_media_tool

HDR_TRANSFERS = {'smpte2084', 'arib-std-b67'}
HDR_UNAVAILABLE = 'HDR 色调映射不可用，画面可能偏亮'
HDR_UNKNOWN = '视频色彩信息不完整，HDR 色调映射未启用，画面可能偏亮'
TONEMAP_FILTER = (
    'zscale=transfer=linear:npl=100,format=gbrpf32le,'
    'tonemap=tonemap=hable:desat=0,'
    'zscale=primaries=bt709:transfer=bt709:matrix=bt709:range=tv,format=yuv420p'
)
SDR_TAGS = ['-color_primaries', 'bt709', '-color_trc', 'bt709',
            '-colorspace', 'bt709', '-color_range', 'tv']


@lru_cache(maxsize=8)
def _filters_available(binary: str) -> bool:
    try:
        result = subprocess.run([binary, '-hide_banner', '-filters'], capture_output=True,
                                text=True, timeout=15, check=True)
        names = {match.group(1) for line in result.stdout.splitlines()
                 if (match := re.match(r'^\s*[TSC.]{2,3}\s+(\S+)\s', line))}
        return {'zscale', 'tonemap'} <= names
    except (OSError, subprocess.SubprocessError):
        return False


def hdr_filter_available() -> bool:
    return _filters_available(resolve_media_tool('ffmpeg'))


def color_plan(info: dict[str, Any]) -> tuple[bool, str | None]:
    """Return mapping decision and optional user-facing warning, without guessing."""
    pix = str(info.get('pix_fmt') or '').lower()
    transfer = str(info.get('color_transfer') or '').lower()
    primaries = str(info.get('color_primaries') or '').lower()
    space = str(info.get('color_space') or '').lower()
    side_data = info.get('side_data_list') or []
    dv = any(isinstance(item, dict) and ('dovi' in str(item.get('side_data_type', '')).lower()
             or 'dolby vision' in str(item.get('side_data_type', '')).lower()
             or item.get('dv_profile') is not None) for item in side_data)
    ten_bit = bool(re.search(r'(?:p10|p010)(?:le|be)?$', pix))
    if not pix or not transfer or pix == 'unknown' or transfer == 'unknown':
        return False, HDR_UNKNOWN
    if transfer not in HDR_TRANSFERS:
        known_sdr = transfer in ('bt709', 'iec61966-2-1', 'gamma22', 'gamma28', 'smpte170m')
        return False, HDR_UNKNOWN if dv or (ten_bit and not known_sdr) else None
    if not ten_bit:
        return False, HDR_UNKNOWN
    if primaries != 'bt2020' or space not in ('bt2020nc', 'bt2020c'):
        return False, HDR_UNKNOWN
    if dv:
        profiles = [item.get('dv_profile') for item in side_data if isinstance(item, dict)
                    and item.get('dv_profile') is not None]
        compatibility = [item.get('dv_bl_signal_compatibility_id') for item in side_data
                         if isinstance(item, dict) and item.get('dv_profile') is not None]
        expected = '1' if transfer == 'smpte2084' else '4'
        if (not profiles or any(str(profile) != '8' for profile in profiles)
                or any(str(value) != expected for value in compatibility)):
            return False, HDR_UNKNOWN
    if not hdr_filter_available():
        return False, HDR_UNAVAILABLE
    return True, None
