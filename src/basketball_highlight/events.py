from .geometry import crossing_x_at_y, is_rim_crossing


def find_candidate_crossings(records, rim, max_gap_sec=2.5, margin=16, dedupe_sec=2.0, min_descent_px=20):
    balls = []
    for record in records:
        detections = [item for item in record.get("detections", []) if item["name"] == "ball"]
        if not detections:
            continue
        detection = max(detections, key=lambda item: item["confidence"])
        balls.append({
            "time": record["time"],
            "x": detection["center"][0],
            "y": detection["center"][1],
            "confidence": detection["confidence"],
        })

    rim_y = rim["rim_y"]
    rim_left = rim["center_x"] - rim["width"] / 2
    rim_right = rim["center_x"] + rim["width"] / 2
    candidates = []

    for index, above in enumerate(balls):
        if above["y"] > rim_y - 8:
            continue
        for below in balls[index + 1:]:
            gap = below["time"] - above["time"]
            if gap <= 0:
                continue
            if gap > max_gap_sec:
                break
            if below["y"] < rim_y + 10:
                continue
            if below["y"] - above["y"] < min_descent_px:
                continue
            x_cross = crossing_x_at_y(above, below, rim_y)
            if x_cross is None or not is_rim_crossing(x_cross, rim_left, rim_right, margin):
                continue
            candidate = {
                "time": round((above["time"] + below["time"]) / 2, 2),
                "x_cross": round(x_cross),
                "above": above,
                "below": below,
            }
            if not candidates or candidate["time"] - candidates[-1]["time"] > dedupe_sec:
                candidates.append(candidate)
            break

    return candidates
