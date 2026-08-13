from create_proxy import progress_from_ffmpeg_line


def test_progress_from_ffmpeg_line_converts_microseconds():
    assert progress_from_ffmpeg_line("out_time_us=5000000", 20.0) == 0.25


def test_progress_from_ffmpeg_line_ignores_unrelated_or_unknown_duration():
    assert progress_from_ffmpeg_line("frame=10", 20.0) is None
    assert progress_from_ffmpeg_line("out_time_us=5000000", None) is None
