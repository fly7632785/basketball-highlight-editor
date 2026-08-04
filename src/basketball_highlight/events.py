from .geometry import crossing_x_at_y, is_rim_crossing


def _flatten_balls(records, min_conf=0.0):
    balls = []
    for record in records:
        detections = [
            item for item in record.get("detections", [])
            if item["name"] == "ball" and item["confidence"] >= min_conf
        ]
        if not detections:
            continue
        detection = max(detections, key=lambda item: item["confidence"])
        balls.append({
            "time": record["time"],
            "x": detection["center"][0],
            "y": detection["center"][1],
            "confidence": detection["confidence"],
        })
    return balls


def find_candidate_crossings(records, rim, max_gap_sec=2.5, margin=16, dedupe_sec=2.0, min_descent_px=20):
    balls = _flatten_balls(records)

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


def find_refined_crossings(records, rim):
    balls = _flatten_balls(records, min_conf=0.25)
    rim_y = rim["rim_y"]
    rim_left = rim["center_x"] - rim["width"] / 2
    rim_right = rim["center_x"] + rim["width"] / 2
    candidates = []

    for index, above in enumerate(balls):
        if above["y"] > rim_y - 15:
            continue
        previous = [
            point for point in balls[max(0, index - 8):index + 1]
            if above["time"] - point["time"] <= 0.5 and point["y"] <= rim_y - 8
        ]
        if len(previous) < 2:
            continue

        for below in balls[index + 1:]:
            gap = below["time"] - above["time"]
            if gap <= 0:
                continue
            if gap > 0.8:
                break
            if below["y"] < rim_y + 18:
                continue
            descent = below["y"] - above["y"]
            if descent < 35 or descent / gap < 60:
                continue
            x_cross = crossing_x_at_y(above, below, rim_y)
            if x_cross is None or not is_rim_crossing(x_cross, rim_left, rim_right, 5):
                continue
            horizontal_ratio = abs(below["x"] - above["x"]) / max(1, descent)
            if horizontal_ratio > 1.2:
                continue

            later = [
                point for point in balls
                if below["time"] <= point["time"] <= below["time"] + 0.5
            ]
            below_points = [point for point in later if point["y"] >= rim_y + 10]
            if len(below_points) < 2:
                continue
            if any(point["y"] < rim_y - 8 for point in later):
                continue

            candidates.append({
                "time": round((above["time"] + below["time"]) / 2, 2),
                "x_cross": round(x_cross),
                "speed_px_s": round(descent / gap, 1),
                "horizontal_ratio": round(horizontal_ratio, 2),
                "above": above,
                "below": below,
            })
            break

    deduped = []
    for candidate in candidates:
        if not deduped or candidate["time"] - deduped[-1]["time"] > 2.0:
            deduped.append(candidate)
    return deduped
