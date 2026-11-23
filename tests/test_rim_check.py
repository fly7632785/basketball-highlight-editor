from basketball_highlight.rim_check import (
    apply_video_occlusion,
    assess_rim_crossing,
    keep_unless_seen,
    rejection_reason,
    net_motion_score,
    skipped_result,
    tight_crop_box,
)

RIM = {"center_x": 500.0, "rim_y": 300.0, "width": 50.0, "height": 20.0}


def ball(x, y, conf=0.85, rim=RIM):
    """Detection at rim-normalized position (x, y)."""
    cx = rim["center_x"] + x * rim["width"]
    cy = rim["rim_y"] + y * rim["width"]
    half = rim["width"] * 0.25
    return {"name": "ball", "confidence": conf, "xyxy": [cx - half, cy - half, cx + half, cy + half]}


def fall(x_start=0.3, x_end=-0.2, hidden=(), steps=16, extra=None):
    """Ball falling from above the rim to below the net, one frame per step."""
    frames = []
    for step in range(steps):
        y = -1.5 + step * 0.25
        x = x_start + (x_end - x_start) * step / (steps - 1)
        detections = [] if step in hidden else [ball(x, y)]
        if extra:
            detections.append(extra)
        frames.append(detections)
    return frames


def test_ball_hidden_by_net_while_passing_the_rim_is_a_make():
    # Steps 6-7 sit at y=0.0/0.25: the ball is inside the rim and net.
    result = assess_rim_crossing(fall(hidden={6, 7}), RIM)
    assert result["status"] == "made"
    assert result["reason"] is None
    assert result["hidden_frames"] == 2


def test_ball_that_stays_fully_visible_fell_in_front_of_the_rim():
    result = assess_rim_crossing(fall(), RIM)
    assert result["status"] == "rejected"
    assert result["reason"] == "not_occluded"


def test_low_confidence_frames_count_as_occlusion():
    frames = fall()
    frames[6] = [ball(0.07, 0.0, conf=0.3)]
    result = assess_rim_crossing(frames, RIM)
    assert result["status"] == "made"


def test_a_ball_rolling_on_the_rim_edge_can_still_be_a_make():
    result = assess_rim_crossing(fall(x_start=0.8, x_end=0.4, hidden={6, 7}), RIM)
    assert 0.5 < result["x_cross"] < 0.7
    assert result["status"] == "made"


def test_crossing_outside_the_rim_opening_is_rejected():
    result = assess_rim_crossing(fall(x_start=0.9, x_end=0.6, hidden={6, 7}), RIM)
    assert result["status"] == "rejected"
    assert result["reason"] == "off_center"


def test_ball_bouncing_back_up_near_the_rim_is_rejected():
    frames = fall(hidden={6})
    # Back up from y=0.75 to y=0.25, then falls away.
    frames = frames[:10] + [[ball(0.0, 0.25)], [ball(0.0, 0.3)]] + frames[10:]
    result = assess_rim_crossing(frames, RIM)
    assert result["status"] == "rejected"
    assert result["reason"] == "rebound"


def test_first_ball_leaves_net_as_second_ball_rises():
    # L477 at 141.020s: a falling ball reaches the net bottom, then the
    # nearest detection rises while the first ball continues below the net.
    frames = [
        [ball(.51, -.77)], [ball(.24, -.51)], [ball(-.05, -.23)],
        [], [], [],
        [ball(.07, .73)], [ball(.15, .90)], [ball(.11, 1.17)],
        [ball(-.08, .78, conf=.87)], [ball(-.16, .53, conf=.88)],
        [ball(-.20, .24)], [ball(-.32, .09)],
    ]
    falling = [(8, .29, 1.14), (9, .43, 1.63), (10, .51, 1.90), (11, .59, 2.20)]
    for offset in (None, .65, 0):
        detections = [frame.copy() for frame in frames]
        if offset is not None:
            for index, x, y in falling:
                detections[index].append(ball(x + offset, y, conf=.70))
        result = assess_rim_crossing(detections, RIM)
        assert result["reached_net_bottom"] is True
        if offset == 0:
            assert result["status"] == "made"
            assert result["rebound"] is False
        else:
            assert result["status"] == "rejected"
            assert result["reason"] == "rebound"


def test_ball_lost_before_leaving_the_net_is_rejected():
    frames = fall(hidden={6, 7})[:9]
    result = assess_rim_crossing(frames, RIM)
    assert result["status"] == "rejected"
    assert result["reason"] == "no_exit"


def test_static_false_detection_does_not_create_a_crossing():
    still = ball(0.1, -0.4, conf=0.6)
    frames = [[still] for _ in range(20)]
    result = assess_rim_crossing(frames, RIM)
    assert result["status"] == "rejected"
    assert result["reason"] == "no_crossing"


def test_static_false_detection_does_not_hide_a_real_make():
    result = assess_rim_crossing(fall(hidden={6, 7}, extra=ball(1.5, -1.0, conf=0.6)), RIM)
    assert result["status"] == "made"


def test_small_rims_are_left_for_manual_review():
    rim = {**RIM, "width": 17.0}
    result = assess_rim_crossing(fall(hidden={6, 7}), rim)
    assert result["status"] == "skipped"
    assert result["reason"] == "small_rim"


def test_tight_crop_stays_inside_the_frame():
    assert tight_crop_box(RIM, 1920, 1080) == [375, 212, 625, 462]
    edge = {**RIM, "center_x": 10.0, "rim_y": 10.0}
    x1, y1, x2, y2 = tight_crop_box(edge, 1920, 1080)
    assert (x1, y1) == (0, 0)
    assert x2 - x1 == y2 - y1 == 250


def video(hidden_makes, visible_falls):
    """Rim checks of one video: falls hidden by the net and fully visible ones."""
    return (
        [assess_rim_crossing(fall(hidden={6, 7}), RIM) for _ in range(hidden_makes)]
        + [assess_rim_crossing(fall(), RIM) for _ in range(visible_falls)]
    )


def test_occlusion_is_ignored_when_the_net_rarely_hides_the_ball():
    # Close, low camera with a thin net: clean makes stay fully visible.
    others = [assess_rim_crossing(fall(x_start=0.9, x_end=0.6, hidden={6, 7}), RIM), skipped_result("small_rim", 20)]
    judged = apply_video_occlusion(video(2, 8) + others)
    assert [result["status"] for result in judged[:10]] == ["made"] * 10
    assert judged[0]["occlusion_rule"] is False
    assert judged[0]["occluded_share"] == 0.2
    assert judged[10]["reason"] == "off_center"
    assert judged[11] == skipped_result("small_rim", 20)


def test_occlusion_still_rejects_falls_in_front_when_the_net_hides_makes():
    judged = apply_video_occlusion(video(9, 2))
    assert [result["reason"] for result in judged[-2:]] == ["not_occluded", "not_occluded"]
    assert judged[0]["occlusion_rule"] is True


def test_occlusion_rule_is_kept_when_too_few_crossings_to_judge_the_video():
    judged = apply_video_occlusion(video(1, 6))
    assert [result["reason"] for result in judged[1:]] == ["not_occluded"] * 6


def net(push):
    """Net motion series: 1.0 until frame 36, then ``push``."""
    return [None] + [1.0] * 36 + [push] * 30


def late_fall(push, hidden=()):
    """A fall that crosses the rim at frame 36 (38 when hidden), with net motion."""
    return assess_rim_crossing([[] for _ in range(30)] + fall(hidden=hidden), RIM, net(push))


def test_net_motion_is_the_push_after_the_crossing_over_the_quiet_before():
    assert late_fall(9.0)["cross_frame"] == 36
    assert late_fall(9.0)["net_motion"] == 8.0
    assert late_fall(9.0, hidden={6, 7})["net_motion"] == 8.0
    # Too few frames before the crossing to know how still the net was.
    assert net_motion_score(net(9.0), 5) is None
    assert assess_rim_crossing(fall(), RIM)["net_motion"] is None


def test_a_still_net_rejects_the_crossing_when_the_net_does_not_hide_the_ball():
    makes = [late_fall(9.0, hidden={6, 7}), late_fall(9.0)] + [late_fall(9.0) for _ in range(6)]
    in_front = [late_fall(0.5), late_fall(0.2, hidden={6, 7})]
    judged = apply_video_occlusion(makes + in_front)
    assert judged[0]["occlusion_rule"] is False
    assert [result["status"] for result in judged[:8]] == ["made"] * 8
    assert [result["reason"] for result in judged[8:]] == ["net_still", "net_still"]


def test_net_motion_is_ignored_while_the_occlusion_rule_applies():
    judged = apply_video_occlusion(
        [late_fall(9.0, hidden={6, 7}) for _ in range(8)] + [late_fall(1.0, hidden={6, 7}), late_fall(9.0)]
    )
    assert judged[0]["occlusion_rule"] is True
    assert judged[8]["status"] == "made"
    assert judged[9]["reason"] == "not_occluded"


def test_a_net_that_moves_a_little_is_not_proof_of_a_miss():
    # How hard a make pushes the net depends on the camera and the net.
    makes = [late_fall(9.0, hidden={6, 7}), late_fall(9.0)] + [late_fall(9.0) for _ in range(6)]
    judged = apply_video_occlusion(makes + [late_fall(1.5)])
    assert judged[-1]["status"] == "made"


def rejected(reason, **features):
    return {"status": "rejected", "reason": reason, **features}


def test_missing_observations_never_prove_a_miss():
    for reason in ("no_crossing", "no_entry", "no_exit"):
        assert keep_unless_seen(rejected(reason), refined=True)["status"] == "unsure"
        assert keep_unless_seen(rejected(reason), refined=False)["status"] == "unsure"
        # A ball fell toward the rim, but a player or the rim hid what happened.
        assert keep_unless_seen(rejected(reason, ball_approached=True), refined=False)["status"] == "unsure"


def test_observed_misses_take_precedence_over_missing_entry_or_exit():
    incomplete = {
        "entry": False, "x_cross": 0.0, "x_exit": None,
        "reached_net_bottom": False, "rebound": False, "hidden_frames": 2,
        "track_points": 12, "track_span": 2.0,
    }
    for evidence, reason in [
        ({"rebound": True}, "rebound"),
        ({"x_exit": 1.0}, "exit_off_center"),
        ({"x_cross": 1.0}, "off_center"),
    ]:
        crossing = {**incomplete, **evidence}
        assert rejection_reason(crossing) == reason
        assert keep_unless_seen(rejected(reason, **crossing), refined=False)["status"] == "rejected"


def test_a_ball_falling_toward_the_rim_is_noticed_even_when_it_is_lost_at_the_rim():
    lost_at_rim = assess_rim_crossing(fall()[:6], RIM)
    assert lost_at_rim["reason"] == "no_crossing"
    assert lost_at_rim["ball_approached"] is True
    assert assess_rim_crossing([[] for _ in range(16)], RIM)["ball_approached"] is False


def test_an_off_center_crossing_excludes_only_on_a_long_falling_track():
    assert keep_unless_seen(rejected("off_center", track_points=9, track_span=2.0), refined=True)["status"] == "unsure"
    # A jersey next to the rim barely moves up or down.
    assert keep_unless_seen(rejected("off_center", track_points=12, track_span=0.45), refined=True)["status"] == "unsure"
    assert keep_unless_seen(rejected("off_center", track_points=10, track_span=1.0), refined=True)["status"] == "rejected"


def test_an_off_center_fall_reports_how_far_the_ball_fell():
    result = assess_rim_crossing(fall(x_start=1.2, x_end=0.9), RIM)
    assert result["reason"] == "off_center"
    assert result["track_span"] == 3.75


def test_weak_off_center_does_not_hide_independent_counterevidence():
    for evidence, reason in [
        ({"x_exit": 1.0}, "exit_off_center"),
        ({"rebound": True}, "rebound"),
    ]:
        result = rejected("off_center", track_points=9, track_span=1.25, **evidence)
        for refined in (False, True):
            judged = keep_unless_seen(result, refined=refined)
            assert judged["status"] == "rejected"
            assert judged["reason"] == reason


def test_a_visible_ball_excludes_only_where_the_net_hides_nearly_every_make():
    assert keep_unless_seen(rejected("not_occluded", occluded_share=0.7), refined=True)["status"] == "unsure"
    assert keep_unless_seen(rejected("not_occluded", occluded_share=0.86), refined=True)["status"] == "rejected"


def test_seen_misses_and_makes_are_kept_as_judged():
    for reason in ("exit_off_center", "rebound", "net_still"):
        assert keep_unless_seen(rejected(reason), refined=True)["status"] == "rejected"
    made = {"status": "made", "reason": None}
    assert keep_unless_seen(made, refined=False) == made
