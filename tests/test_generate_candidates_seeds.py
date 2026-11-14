"""find_rim_band_seeds:筐带单次目击的弱种子候选。"""

from generate_candidates import find_rim_band_seeds


RIM = {
    "center_x": 580.0,
    "rim_y": 230.0,
    "width": 25.0,
    "height": 25.0,
    "source": "median_hoop_detections",
}


def _record(time, detections):
    return {"time": time, "detections": detections}


def _ball(x, y, confidence=0.5):
    return {
        "name": "ball",
        "confidence": confidence,
        "center": [x, y],
        "xyxy": [x - 10, y - 10, x + 10, y + 10],
    }


def test_rim_band_sighting_becomes_seed():
    records = [
        _record(7.0, [_ball(575.0, 210.0)]),
        _record(30.0, [_ball(584.0, 250.0, 0.4)]),
    ]

    seeds = find_rim_band_seeds(records, RIM, [])

    assert [seed["time"] for seed in seeds] == [7.0, 30.0]
    assert seeds[0]["seed"] == "rim_band_sighting"
    # above 与配对候选同构(扁平 x/y/time),refine 的兜底轨迹直接读这些键。
    assert seeds[0]["above"] == {
        "time": 7.0, "x": 575.0, "y": 210.0, "confidence": 0.5,
    }
    assert seeds[0]["below"] is None


def test_sighting_outside_rim_band_is_ignored():
    records = [
        _record(1.0, [_ball(400.0, 210.0)]),   # 筐带左侧太远
        _record(2.0, [_ball(580.0, 80.0)]),    # 筐带上方太高
        _record(3.0, [_ball(580.0, 420.0)]),   # 筐带下方太深(运球/地板球)
        _record(4.0, [_ball(760.0, 230.0)]),   # 筐带右侧太远
    ]

    assert find_rim_band_seeds(records, RIM, []) == []


def test_above_rim_sightings_win_over_net_zone_false_positives():
    # 同一时刻筐上目击与篮网静态误检并存,优先保留筐上目击。
    records = [
        _record(10.0, [_ball(578.0, 245.0, 0.9), _ball(575.0, 205.0, 0.2)]),
    ]

    seeds = find_rim_band_seeds(records, RIM, [], dedupe_sec=2.0)

    assert len(seeds) == 1
    assert seeds[0]["above"]["y"] == 205.0


def test_sightings_dedupe_within_cluster():
    records = [
        _record(14.0, [_ball(575.0, 205.0)]),
        _record(14.2, [_ball(578.0, 220.0)]),
        _record(15.0, [_ball(582.0, 250.0)]),
        _record(20.0, [_ball(580.0, 210.0)]),
    ]

    seeds = find_rim_band_seeds(records, RIM, [], dedupe_sec=2.0)

    assert [seed["time"] for seed in seeds] == [14.0, 20.0]


def test_seeds_skip_times_near_existing_pair_candidates():
    records = [
        _record(3.0, [_ball(575.0, 205.0)]),   # 距配对候选 2.98s 仅 0.02s
        _record(9.0, [_ball(575.0, 205.0)]),   # 距配对候选 4s 之外
    ]
    pairs = [{"time": 2.98}, {"time": 31.0}]

    seeds = find_rim_band_seeds(records, RIM, pairs, dedupe_sec=2.0)

    assert [seed["time"] for seed in seeds] == [9.0]


def test_seed_count_is_capped():
    records = [
        _record(float(second), [_ball(575.0, 205.0)])
        for second in range(0, 200, 3)
    ]

    seeds = find_rim_band_seeds(records, RIM, [], max_seeds=10)

    assert len(seeds) == 10
