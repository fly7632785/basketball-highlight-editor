from basketball_highlight.sampling import canonical_sample_times, first_frame_index, nearest_frame_index, round_time_ms


def test_sampling_grid_is_half_open_and_does_not_drift():
    assert canonical_sample_times(0.0, 3.0, 3.0) == [0.0, 0.333, 0.667, 1.0, 1.333, 1.667, 2.0, 2.333, 2.667]


def test_sampling_grid_preserves_non_zero_analysis_start():
    assert canonical_sample_times(10.0, 11.0, 2.0) == [10.0, 10.5]


def test_sampling_uses_mobile_rounding_at_half_millisecond():
    assert round_time_ms(2.5) == 3
    assert canonical_sample_times(0.0, 0.004, 400.0) == [0.0, 0.003]


def test_nearest_frame_index_uses_cross_platform_tie_rule():
    assert nearest_frame_index(0.05, 10.0) == 1


def test_first_frame_index_matches_native_decoder_selection():
    assert first_frame_index(0.1, 30.0) == 3
    assert first_frame_index(0.1001, 30.0) == 4
