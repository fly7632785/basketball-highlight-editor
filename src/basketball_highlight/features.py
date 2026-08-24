def normalize_geometry(candidate, rim):
    """Convert pixel geometry into dimensions relative to the detected rim."""
    rim_width = max(1.0, float(rim.get("width", 1.0)))
    rim_height = max(1.0, float(rim.get("height", 1.0)))
    center_x = float(rim.get("center_x", 0.0))
    speed = float(candidate.get("speed_px_s", 0.0))
    span = float(candidate.get("approach_horizontal_span_px", 0.0))
    x_cross = float(candidate.get("x_cross", center_x))
    return {
        "rim_width_px": round(rim_width, 3),
        "rim_height_px": round(rim_height, 3),
        "speed_per_rim": round(speed / rim_width, 3),
        "approach_span_per_rim": round(span / rim_width, 3),
        "crossing_offset_per_rim": round(abs(x_cross - center_x) / rim_width, 3),
        "rim_aspect": round(rim_width / rim_height, 3),
    }
