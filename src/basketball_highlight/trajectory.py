from __future__ import annotations

import math

import numpy as np


def _descent_points(track, rim_y, margin=8.0, max_points=8):
    points = sorted(track, key=lambda item: item["time"])
    above = [point for point in points if point["y"] < rim_y - margin]
    if len(above) < 5:
        return []
    apex_index = min(range(len(above)), key=lambda index: above[index]["y"])
    descent = above[apex_index:]
    if len(descent) < 5:
        return []
    descent = descent[-max_points:]
    if descent[-1]["y"] <= descent[0]["y"] + 2.0:
        return []
    if descent[-1]["time"] - descent[0]["time"] < 0.12:
        return []
    return descent


def fit_descent(track, rim_y, min_points=5, max_points=8, min_r2=0.85):
    """Fit a forward landing model from the clear, above-rim descent segment.

    Screen-space y is modeled as a quadratic over time and x as a linear
    function over time. The fit intentionally uses only points above the rim;
    detections near the net are not allowed to influence the prediction.
    """
    points = _descent_points(track, rim_y, max_points=max_points)
    if len(points) < min_points:
        return None

    times = np.asarray([point["time"] for point in points], dtype=float)
    time_origin = float(times[-1])
    tau = times - time_origin
    y = np.asarray([point["y"] for point in points], dtype=float)
    x = np.asarray([point["x"] for point in points], dtype=float)
    weights = np.exp(np.linspace(-0.7, 0.0, len(points)))

    y_coefficients = np.polyfit(tau, y, 2, w=weights)
    x_coefficients = np.polyfit(tau, x, 1, w=weights)
    predicted_y = np.polyval(y_coefficients, tau)
    residual = float(np.sum((y - predicted_y) ** 2))
    total = float(np.sum((y - np.mean(y)) ** 2))
    r2 = 1.0 if total == 0.0 and residual == 0.0 else 1.0 - residual / max(total, 1e-9)
    r2 = max(0.0, min(1.0, r2))
    if r2 < min_r2:
        return None

    return {
        "y_coefficients": [float(value) for value in y_coefficients],
        "x_coefficients": [float(value) for value in x_coefficients],
        "time_origin": time_origin,
        "last_y": float(y[-1]),
        "last_x": float(x[-1]),
        "fit_r2": round(r2, 4),
        "point_count": len(points),
    }


def predict_landing_x(fit, rim_y):
    """Return the first future x where the fitted y reaches ``rim_y``."""
    if not fit:
        return None
    a, b, c = fit["y_coefficients"]
    c -= rim_y
    roots = []
    if abs(a) < 1e-8:
        if abs(b) < 1e-8:
            return None
        roots = [-c / b]
    else:
        discriminant = b * b - 4.0 * a * c
        if discriminant < 0.0:
            return None
        root = math.sqrt(discriminant)
        roots = [(-b - root) / (2.0 * a), (-b + root) / (2.0 * a)]

    future_roots = [value for value in roots if value > 0.0]
    if not future_roots:
        return None
    tau = min(future_roots)
    x_slope, x_intercept = fit["x_coefficients"]
    return round(float(x_slope * tau + x_intercept), 3)


def prediction_score(track, rim, min_r2=0.85):
    fit = fit_descent(track, rim["rim_y"], min_r2=min_r2)
    if not fit:
        return None
    landing_x = predict_landing_x(fit, rim["rim_y"])
    if landing_x is None:
        return None
    half_width = max(1.0, float(rim["width"]) / 2.0)
    distance = abs(landing_x - float(rim["center_x"]))
    landing_center = max(0.0, 1.0 - distance / half_width)
    return {
        "predict_x": landing_x,
        "landing_center": round(landing_center, 4),
        "fit_r2": fit["fit_r2"],
        "point_count": fit["point_count"],
        "predict_score": round(0.60 * fit["fit_r2"] + 0.40 * landing_center, 4),
    }
