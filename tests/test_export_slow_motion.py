import json
import shutil
import subprocess
from pathlib import Path

import pytest

from engine.python.basketball_engine.adapters import export
from engine.python.basketball_engine.adapters.export import (
    approach_window,
    effect_spec,
    output_duration_ms,
    replay_crop,
    replay_window,
    trajectory_points,
)
from engine.python.basketball_engine.media_tools import resolve_media_tool


def _tools_or_skip() -> tuple[str, str]:
    ffmpeg, ffprobe = resolve_media_tool("ffmpeg"), resolve_media_tool("ffprobe")
    if not shutil.which(ffmpeg) or not shutil.which(ffprobe):
        pytest.skip("需要 ffmpeg/ffprobe")
    return ffmpeg, ffprobe


def _probe(ffprobe: str, path: Path) -> dict:
    out = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries",
         "format=duration:stream=codec_type,width,height,sample_rate,channels", "-of", "json", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)


def _clip(source: Path, *, event_ms=3000, start_ms=1000, end_ms=5000, rim=None, trail=None,
          has_audio=True, manual=False):
    return {
        "source_path": str(source), "width": 320, "height": 240, "fps": 30.0, "has_audio": has_audio,
        "event_time_ms": event_ms, "review_start_ms": start_ms, "review_end_ms": end_ms,
        "manual": manual, "rim": rim, "trail": trail or [],
    }


def _source(tmp_path: Path, ffmpeg: str, with_audio: bool = True) -> Path:
    source = tmp_path / "game.mp4"
    inputs = ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=30"]
    if with_audio:
        inputs += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100"]
    subprocess.run(
        [ffmpeg, "-v", "error", "-y", *inputs, "-t", "8", "-c:v", "mpeg4",
         *(["-c:a", "aac", "-ac", "1"] if with_audio else []), str(source)],
        check=True,
    )
    return source


def test_approach_covers_one_second_before_to_three_tenths_after_the_goal():
    clip = _clip(Path("x.mp4"), event_ms=3000, start_ms=1000, end_ms=5000)
    assert approach_window(clip) == (2000, 3300)
    assert approach_window({**clip, "review_end_ms": 3100}) == (2000, 3100)
    assert approach_window({**clip, "manual": True}) is None


def test_replay_covers_half_a_second_before_to_three_tenths_after_the_goal():
    clip = _clip(Path("x.mp4"), event_ms=3000, start_ms=1000, end_ms=5000)
    assert replay_window(clip) == (2500, 3300)
    assert replay_window({**clip, "event_time_ms": 9000}) is None


def test_trajectory_keeps_only_the_flight_around_the_goal():
    evidence = json.dumps({"overlay": {"trajectory": [
        {"time": 16.0, "x": 818.0, "y": 320.0},
        {"time": 16.6, "x": 900.0, "y": 500.0},
        {"time": 17.2, "x": 1001.0, "y": 588.0},
        {"time": 17.7, "x": 955.0, "y": 801.0},
    ]}})
    assert trajectory_points(evidence, 16_900) == [[900.0, 500.0], [1001.0, 588.0]]
    assert trajectory_points("{}", 16_900) == []


def test_close_up_frames_the_flight_and_stays_inside_the_picture():
    width, height, x, y = replay_crop([[1000.0, 600.0], [1010.0, 620.0]], 1920, 1440, 4 / 3)
    assert (width, height) == (960, 720)  # 小范围：最多放大 2 倍
    assert x <= 1000.0 and 1010.0 <= x + width
    assert y <= 600.0 and 620.0 <= y + height

    wide_w, _, _, _ = replay_crop([[400.0, 500.0], [1200.0, 900.0]], 1920, 1440, 4 / 3)
    assert wide_w >= 800  # 球路很宽：放大得少，不把球路框在外面
    assert replay_crop([], 1920, 1440, 4 / 3) is None


def test_effect_spec_needs_the_data_it_uses():
    clip = _clip(Path("x.mp4"), rim={"x": 1000, "y": 580, "width": 40}, trail=[[1000.0, 580.0]])
    assert effect_spec(clip, "none") is None
    assert effect_spec({**clip, "manual": True}, "approach") is None
    assert effect_spec({**clip, "manual": True}, "replay") is None
    assert effect_spec({**clip, "rim": None, "trail": []}, "replay") is None
    assert effect_spec({**clip, "width": None}, "approach") is None
    assert effect_spec(clip, "approach")["slow"] == (2000, 3300)
    assert effect_spec(clip, "replay")["replay"]["start_ms"] == 2500
    with pytest.raises(ValueError):
        effect_spec(clip, "slow_motion")


def test_output_duration_adds_the_slow_part_or_the_replay():
    clip = _clip(Path("x.mp4"), rim={"x": 1000, "y": 580, "width": 40}, trail=[[1000.0, 580.0]])
    assert output_duration_ms(clip, None) == 4000
    assert output_duration_ms(clip, effect_spec(clip, "approach")) == 5300  # 慢放的 1.3 秒多出 1.3 秒
    assert output_duration_ms(clip, effect_spec(clip, "replay")) == 5600  # 回放 0.8 秒，放慢一倍 1.6 秒


@pytest.mark.parametrize("with_audio", [True, False])
def test_approach_slows_the_goal_in_place(tmp_path: Path, with_audio: bool):
    ffmpeg, ffprobe = _tools_or_skip()
    source = _source(tmp_path, ffmpeg, with_audio)
    clip = _clip(source, has_audio=with_audio)

    result = export.export_goal_clips([clip], tmp_path / "out", "separate", effect="approach")

    info = _probe(ffprobe, Path(result["files"][0]))
    assert float(info["format"]["duration"]) == pytest.approx(5.3, abs=0.2)
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    assert (video["width"], video["height"]) == (320, 240)
    audio = [s for s in info["streams"] if s["codec_type"] == "audio"]
    assert bool(audio) is with_audio
    if with_audio:
        assert (audio[0]["sample_rate"], audio[0]["channels"]) == ("48000", 2)
    assert result["duration_ms"] == 5300


def test_replay_appends_a_close_up_after_the_clip(tmp_path: Path):
    ffmpeg, ffprobe = _tools_or_skip()
    source = _source(tmp_path, ffmpeg)
    clip = _clip(source, rim={"x": 160, "y": 100, "width": 20}, trail=[[160.0, 100.0]])

    result = export.export_goal_clips([clip], tmp_path / "out", "separate", effect="replay")

    info = _probe(ffprobe, Path(result["files"][0]))
    assert float(info["format"]["duration"]) == pytest.approx(5.6, abs=0.2)
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    assert (video["width"], video["height"]) == (320, 240)
    assert any(s["codec_type"] == "audio" for s in info["streams"])


def test_a_clip_without_hoop_data_is_exported_as_it_was(tmp_path: Path):
    ffmpeg, ffprobe = _tools_or_skip()
    source = _source(tmp_path, ffmpeg)
    clip = _clip(source, rim=None, trail=[])

    result = export.export_goal_clips([clip], tmp_path / "out", "separate", effect="replay")

    assert float(_probe(ffprobe, Path(result["files"][0]))["format"]["duration"]) == pytest.approx(4.0, abs=0.2)
    assert result["duration_ms"] == 4000


def test_merge_mixes_effect_and_plain_clips_with_one_audio_format(tmp_path: Path):
    ffmpeg, ffprobe = _tools_or_skip()
    source = _source(tmp_path, ffmpeg)
    clips = [
        _clip(source, rim={"x": 160, "y": 100, "width": 20}, trail=[[160.0, 100.0]]),
        _clip(source, event_ms=7000, start_ms=6000, end_ms=8000, manual=True),  # 手动片段：原样导出
    ]

    result = export.export_goal_clips(clips, tmp_path / "out", "merge", tmp_path / "game.mp4", effect="approach")

    info = _probe(ffprobe, Path(result["files"][0]))
    audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
    assert (audio["sample_rate"], audio["channels"]) == ("48000", 2)
    assert float(info["format"]["duration"]) == pytest.approx(5.3 + 2.0, abs=0.3)
    assert result["duration_ms"] == 5300 + 2000


@pytest.mark.parametrize("mode", ["separate", "merge"])
@pytest.mark.parametrize("effect,manual,duration", [
    ("none", False, 4.0),
    ("approach", False, 5.3),
    ("replay", False, 5.6),
    ("approach", True, 4.0),
])
def test_export_skips_an_unrecognized_audio_track(tmp_path: Path, mode, effect, manual, duration):
    from engine.python.basketball_engine.service import EngineService

    ffmpeg, ffprobe = _tools_or_skip()
    source = _source(tmp_path, ffmpeg)
    # Keep a real audio track, but remove its codec description. Unlike a
    # video with no audio streams, an optional 0:a:0? map still selects it.
    data = bytearray(source.read_bytes())
    audio_tag = data.index(b"mp4a")
    esds_tag = data.index(b"esds", audio_tag)
    data[audio_tag:audio_tag + 4] = b"zzzz"
    data[esds_tag:esds_tag + 4] = b"free"
    source.write_bytes(data)
    info = EngineService().inspect_video({"video_path": str(source)})
    assert info["audio_codec"] is None
    clip = _clip(
        source, has_audio=bool(info["audio_codec"]), manual=manual,
        rim={"x": 160, "y": 100, "width": 20}, trail=[[160.0, 100.0]],
    )

    result = export.export_goal_clips([clip], tmp_path / "out", mode, effect=effect)

    for path in dict.fromkeys(result["clip_files"] + result["files"]):
        output = _probe(ffprobe, Path(path))
        assert [stream["codec_type"] for stream in output["streams"]] == ["video"]
        assert float(output["format"]["duration"]) == pytest.approx(duration, abs=0.2)
