import numpy as np


def merge_time_ranges(ranges):
    """Merge overlapping or touching ``(start, end)`` ranges."""
    merged = []
    for start, end in sorted((float(start), float(end)) for start, end in ranges):
        if end <= start:
            continue
        if not merged or start > merged[-1][1]:
            merged.append([start, end])
        else:
            merged[-1][1] = max(merged[-1][1], end)
    return [tuple(item) for item in merged]


def _validate_sample_rate(sample_rate):
    if not np.isfinite(sample_rate) or sample_rate <= 0:
        raise ValueError("SAMPLE_RATE_INVALID")


def _slice_window(samples, sample_rate, start, end):
    _validate_sample_rate(sample_rate)
    values = np.asarray(samples, dtype=np.float32).reshape(-1)
    start_index = max(0, int(round(start * sample_rate)))
    end_index = min(values.size, int(round(end * sample_rate)))
    return values[start_index:end_index]


def audio_features(samples, sample_rate):
    """Return inexpensive impact/noise features for a mono PCM window."""
    _validate_sample_rate(sample_rate)
    values = np.asarray(samples, dtype=np.float32).reshape(-1)
    if values.size == 0:
        return {
            "rms": 0.0,
            "peak": 0.0,
            "crest_factor": 0.0,
            "spectral_flux": 0.0,
            "high_band_ratio": 0.0,
        }

    rms = float(np.sqrt(np.mean(values * values)))
    peak = float(np.max(np.abs(values)))
    crest_factor = peak / rms if rms > 1e-9 else 0.0

    frame_size = max(32, int(sample_rate * 0.05))
    hop = max(16, frame_size // 2)
    if values.size < frame_size:
        padded = np.pad(values, (0, frame_size - values.size))
        frames = padded[None, :]
    else:
        count = 1 + (values.size - frame_size) // hop
        frames = np.stack([
            values[index * hop:index * hop + frame_size]
            for index in range(count)
        ])
    window = np.hanning(frame_size).astype(np.float32)
    spectrum = np.abs(np.fft.rfft(frames * window, axis=1))
    spectrum /= np.maximum(spectrum.sum(axis=1, keepdims=True), 1e-9)
    flux = np.maximum(0.0, np.diff(spectrum, axis=0)).sum(axis=1)

    frequencies = np.fft.rfftfreq(frame_size, 1.0 / sample_rate)
    high_band = (frequencies >= 2000.0) & (frequencies <= 8000.0)
    high_band_ratio = float(spectrum[:, high_band].sum(axis=1).mean())
    return {
        "rms": rms,
        "peak": peak,
        "crest_factor": float(crest_factor),
        "spectral_flux": float(flux.mean()) if flux.size else 0.0,
        "high_band_ratio": high_band_ratio,
    }


def event_window_features(
    samples,
    sample_rate,
    event_offset,
    baseline_start=-1.0,
    baseline_end=-0.2,
    active_start=-0.1,
    active_end=0.8,
):
    """Compare audio immediately around an event with its local baseline.

    ``samples`` starts at the beginning of the decoded window and
    ``event_offset`` points to the event inside that window.  The output is
    deliberately relative rather than absolute so microphone gain differences
    do not become a hard-coded cross-video threshold.
    """
    baseline = _slice_window(
        samples, sample_rate, event_offset + baseline_start, event_offset + baseline_end,
    )
    active = _slice_window(
        samples, sample_rate, event_offset + active_start, event_offset + active_end,
    )
    baseline_result = audio_features(baseline, sample_rate)
    active_result = audio_features(active, sample_rate)
    epsilon = 1e-6
    rms_ratio = active_result["rms"] / max(baseline_result["rms"], epsilon)
    rms_db_delta = 20.0 * np.log10(
        max(active_result["rms"], epsilon) / max(baseline_result["rms"], epsilon),
    )
    peak_ratio = active_result["peak"] / max(baseline_result["peak"], epsilon)
    return {
        "baseline_rms": round(baseline_result["rms"], 6),
        "active_rms": round(active_result["rms"], 6),
        "rms_delta": round(max(0.0, active_result["rms"] - baseline_result["rms"]), 6),
        "rms_ratio": round(float(rms_ratio), 4),
        "rms_db_delta": round(float(rms_db_delta), 3),
        "baseline_peak": round(baseline_result["peak"], 6),
        "active_peak": round(active_result["peak"], 6),
        "peak_ratio": round(float(peak_ratio), 4),
        "active_crest_factor": round(active_result["crest_factor"], 4),
        "active_spectral_flux": round(active_result["spectral_flux"], 6),
        "active_high_band_ratio": round(active_result["high_band_ratio"], 6),
    }
