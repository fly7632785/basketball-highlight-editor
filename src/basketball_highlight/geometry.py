def crossing_x_at_y(above, below, crossing_y):
    if below["y"] <= above["y"]:
        return None
    if not above["y"] <= crossing_y <= below["y"]:
        return None
    fraction = (crossing_y - above["y"]) / (below["y"] - above["y"])
    return above["x"] + fraction * (below["x"] - above["x"])


def is_rim_crossing(crossing_x, rim_left, rim_right, margin):
    return rim_left - margin <= crossing_x <= rim_right + margin
