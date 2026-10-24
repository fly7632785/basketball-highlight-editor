from create_proxy import progress_from_ffmpeg_line, proxy_attempts


def test_progress_from_ffmpeg_line_converts_microseconds():
    assert progress_from_ffmpeg_line("out_time_us=5000000", 20.0) == 0.25


def test_progress_from_ffmpeg_line_ignores_unrelated_or_unknown_duration():
    assert progress_from_ffmpeg_line("frame=10", 20.0) is None
    assert progress_from_ffmpeg_line("out_time_us=5000000", None) is None


def test_proxy_attempts_prefer_libx264_on_mac_and_keep_hardware_decode():
    assert proxy_attempts("auto", "auto", "Darwin") == [
        ("libx264", "videotoolbox"),
        ("h264_videotoolbox", "videotoolbox"),
        ("mpeg4", "none"),
    ]


def test_proxy_attempts_decode_on_the_gpu_on_windows_then_fall_back_to_software():
    assert proxy_attempts("auto", "auto", "Windows") == [
        ("libx264", "d3d11va"), ("mpeg4", "d3d11va"), ("mpeg4", "none"),
    ]


def test_proxy_attempts_respect_explicit_choices():
    assert proxy_attempts("libx264", "none", "Windows") == [("libx264", "none")]
    assert proxy_attempts("auto", "auto", "Linux") == [("libx264", "none"), ("mpeg4", "none")]
