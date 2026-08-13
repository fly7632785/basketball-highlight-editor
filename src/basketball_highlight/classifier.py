import numpy as np


FEATURE_NAMES = (
    "speed_per_rim",
    "approach_span_per_rim",
    "crossing_offset_per_rim",
    "horizontal_ratio",
    "approach_rise_per_rim",
    "approach_downward_ratio",
    "trajectory_score",
    "net_motion_score",
    "net_changed_ratio",
    "net_score",
    "prediction_landing_center",
    "prediction_fit_r2",
    "prediction_score",
    "audio_rms_db_delta",
    "audio_rms_ratio",
    "audio_peak_ratio",
    "audio_spectral_flux",
    "audio_high_band_ratio",
)


def _number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def match_feature_vector(match, audio=None):
    signals = match.get("signals", {})
    prediction = match.get("prediction") or {}
    audio = audio or {}
    return np.asarray([
        _number(match.get("speed_per_rim")),
        _number(match.get("approach_span_per_rim")),
        _number(match.get("crossing_offset_per_rim")),
        _number(match.get("horizontal_ratio")),
        _number(match.get("approach_rise_px")) /
        max(1.0, _number(match.get("rim_width_px", 1.0))),
        _number(match.get("approach_downward_ratio")),
        _number(match.get("trajectory_score")),
        _number(match.get("net_motion_score")),
        _number(match.get("net_changed_ratio")),
        _number(signals.get("net_score")),
        _number(prediction.get("landing_center")),
        _number(prediction.get("fit_r2")),
        _number(prediction.get("predict_score")),
        _number(audio.get("rms_db_delta")),
        _number(audio.get("rms_ratio")),
        _number(audio.get("peak_ratio")),
        _number(audio.get("active_spectral_flux")),
        _number(audio.get("active_high_band_ratio")),
    ], dtype=float)


def _sigmoid(values):
    values = np.clip(values, -40.0, 40.0)
    return 1.0 / (1.0 + np.exp(-values))


def fit_logistic(features, labels, steps=800, learning_rate=0.05, l2=1.0):
    """Fit a small regularized logistic model without a heavyweight dependency."""
    values = np.asarray(features, dtype=float)
    targets = np.asarray(labels, dtype=float).reshape(-1)
    if values.ndim != 2 or len(values) != len(targets) or len(values) == 0:
        raise ValueError("features and labels must have matching non-empty rows")
    mean = values.mean(axis=0)
    scale = values.std(axis=0)
    scale[scale < 1e-9] = 1.0
    normalized = (values - mean) / scale
    design = np.column_stack([np.ones(len(normalized)), normalized])
    weights = np.zeros(design.shape[1], dtype=float)
    positive = max(1.0, float(targets.sum()))
    negative = max(1.0, float(len(targets) - targets.sum()))
    sample_weights = np.where(targets > 0.5, len(targets) / (2.0 * positive),
                              len(targets) / (2.0 * negative))
    for _ in range(steps):
        probabilities = _sigmoid(design @ weights)
        gradient = (design.T @ (sample_weights * (probabilities - targets))) / len(targets)
        gradient[1:] += l2 * weights[1:] / len(targets)
        weights -= learning_rate * gradient
    return {
        "mean": mean,
        "scale": scale,
        "weights": weights,
        "feature_names": FEATURE_NAMES,
    }


def predict_proba(model, features):
    values = np.asarray(features, dtype=float)
    normalized = (values - model["mean"]) / model["scale"]
    design = np.column_stack([np.ones(len(normalized)), normalized])
    return _sigmoid(design @ model["weights"])
