from basketball_highlight.tracking import link_ball_detections


def _record(time, *centers):
    return {
        "time": time,
        "detections": [
            {"name": "ball", "center": [x, y]}
            for x, y in centers
        ],
    }


def test_link_ball_detections_chooses_nearest_regardless_of_detection_order():
    anchor = {"time": 9.9, "x": 100.0, "y": 50.0}
    records = [
        _record(10.0, (190.0, 55.0), (105.0, 55.0)),
        _record(10.1, (110.0, 75.0)),
    ]

    far_first = link_ball_detections(records, anchor=anchor, rim_width=40.0)
    records[0]["detections"].reverse()
    near_first = link_ball_detections(records, anchor=anchor, rim_width=40.0)

    assert far_first == near_first
    assert [(point["x"], point["y"]) for point in far_first] == [
        (100.0, 50.0),
        (105.0, 55.0),
        (110.0, 75.0),
    ]


def test_link_ball_detections_tracks_both_directions_from_candidate_anchor():
    records = [
        _record(9.7, (70.0, 35.0), (400.0, 400.0)),
        _record(9.8, (85.0, 40.0), (390.0, 390.0)),
        _record(10.0, (110.0, 70.0), (380.0, 380.0)),
    ]

    trajectory = link_ball_detections(
        records,
        anchor={"time": 9.9, "x": 100.0, "y": 50.0},
        rim_width=40.0,
    )

    assert [(point["time"], point["x"], point["y"]) for point in trajectory] == [
        (9.7, 70.0, 35.0),
        (9.8, 85.0, 40.0),
        (9.9, 100.0, 50.0),
        (10.0, 110.0, 70.0),
    ]


def test_link_ball_detections_scales_gate_with_rim_width():
    base = link_ball_detections(
        [_record(10.0, (150.0, 70.0), (260.0, 70.0))],
        anchor={"time": 9.9, "x": 100.0, "y": 50.0},
        rim_width=40.0,
    )
    scaled = link_ball_detections(
        [_record(10.0, (600.0, 280.0), (1040.0, 280.0))],
        anchor={"time": 9.9, "x": 400.0, "y": 200.0},
        rim_width=160.0,
    )

    assert [(point["x"] * 4, point["y"] * 4) for point in base] == [
        (point["x"], point["y"])
        for point in scaled
    ]


def test_link_ball_detections_does_not_bridge_long_detection_gaps():
    trajectory = link_ball_detections(
        [
            _record(10.1, (110.0, 60.0)),
            _record(11.0, (120.0, 70.0)),
        ],
        anchor={"time": 10.0, "x": 100.0, "y": 50.0},
        rim_width=40.0,
        max_gap_seconds=0.5,
    )

    assert [point["time"] for point in trajectory] == [10.0, 10.1]


def test_link_ball_detections_ignores_malformed_detection_entries():
    trajectory = link_ball_detections(
        [{"time": 10.1, "detections": [None, "ball", {"name": "ball"}]}],
        anchor={"time": 10.0, "x": 100.0, "y": 50.0},
        rim_width=40.0,
    )

    assert trajectory == [{"time": 10.0, "x": 100.0, "y": 50.0}]
