"""Read-time tiers; original analysis evidence and manual decisions stay intact."""
from __future__ import annotations

import json
import math
from statistics import median

RULE_VERSION = 'r2-v1'
TIERS = {'must', 'suspect', 'excluded'}


def evidence_dict(value):
    try:
        value = json.loads(value) if isinstance(value, str) else value
    except (ValueError, TypeError):
        return {}
    return dict(value) if isinstance(value, dict) else {}


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def seen_miss(evidence):
    check = evidence_dict(evidence.get('rim_check'))
    supported_side = (check.get('status') == 'rejected'
                      and check.get('reason') in {'off_center', 'exit_off_center'}
                      and finite(check.get('track_points')) and check['track_points'] >= 10
                      and finite(check.get('track_span')) and check['track_span'] >= 1)
    return (evidence.get('rebound') is True or evidence.get('lateral_exit') is True
            or check.get('rebound') is True or supported_side
            or (check.get('status') == 'rejected' and check.get('reason') == 'rebound'))


def never_near_rim(evidence):
    """A queue hint, not proof of a miss: stored tracks can omit real goals."""
    evidence = evidence_dict(evidence)
    check = evidence_dict(evidence.get('rim_check'))
    if (check.get('status') not in {'unsure', 'rejected'}
            or check.get('reason') not in {'no_crossing', 'no_entry', 'no_exit'}):
        return False
    overlay = evidence_dict(evidence.get('overlay'))
    rim = evidence_dict(overlay.get('rim'))
    points = overlay.get('trajectory')
    # The overlay rim and its points share coordinates; the coarse rim may not.
    if (not all(finite(rim.get(key)) for key in ('center_x', 'rim_y', 'width'))
            or rim['width'] <= 0 or not isinstance(points, list) or not points):
        return False
    if any(not isinstance(point, dict) or not finite(point.get('x'))
           or not finite(point.get('y')) for point in points):
        return False
    return not any(abs((point['x'] - rim['center_x']) / rim['width']) <= .6
                   and -.6 <= (point['y'] - rim['rim_y']) / rim['width'] <= 1.2
                   for point in points)


def classify(evidence, mode='standard', rule_version=RULE_VERSION):
    evidence = evidence_dict(evidence)
    def result(tier, reason, source='algorithm'):
        return dict(tier=tier, reason=reason, source=source)
    status = evidence.get('review_status')
    if evidence.get('review_reason') != 'auto_rim_check':
        if status == 'goal':
            return result('must', 'user_goal', 'user')
        if status == 'excluded':
            return result('excluded', 'user_excluded', 'user')
    if rule_version != RULE_VERSION:
        return result('suspect', 'unsupported_rule_version')
    if mode == 'fast' or evidence.get('analysis_mode') == 'fast':
        return result('suspect', 'fast_analysis')
    # Original-video rim evidence can establish an existing miss even for coarse candidates.
    miss = seen_miss(evidence)
    if miss and status == 'excluded' and evidence.get('review_reason') == 'auto_rim_check':
        return result('excluded', 'seen_miss')
    if evidence.get('analysis_source') != 'refined':
        return result('suspect', 'missing_refined_evidence')
    gates = evidence_dict(evidence.get('gates'))
    if any(value is True or str(value).lower() == "true" for value in (evidence.get('conflict'), evidence.get('evidence_conflict'),
                                       gates.get('evidence_conflict'), gates.get('signal_conflict'))):
        return result('suspect', 'conflicting_evidence')
    check = evidence_dict(evidence.get('rim_check'))
    if miss or check.get('reason') in {'rebound', 'off_center', 'exit_off_center'}:
        return result('suspect', 'contrary_evidence')
    if check.get('status') != 'made' or check.get('rebound') is not False:
        return result('suspect', 'missing_made_evidence')
    calibration = evidence_dict(evidence.get('tier_calibration'))
    if not calibration:
        saved = evidence_dict(evidence_dict(check.get('experiment')).get('net_calibration'))
        if saved.get('scope') == 'analysis_run_baseline_made':
            calibration = saved
    samples, mid = calibration.get('samples'), calibration.get('median')
    if not finite(samples) or samples < 8 or not finite(mid) or mid <= 0:
        return result('suspect', 'missing_calibration')
    value = check.get('net_motion')
    if not finite(value):
        return result('suspect', 'missing_net_motion')
    if value < mid * .30:
        return result('suspect', 'weak_net_motion')
    return result('must', 'r2_net_motion')


def calibration_from_rows(rows):
    """Calculate a baseline without changing evidence or persisting anything."""
    values = []
    for row in rows:
        evidence = evidence_dict(row.get('evidence_json'))
        check = evidence_dict(evidence.get('rim_check'))
        value = check.get('net_motion')
        if evidence.get('analysis_source') == 'refined' and check.get('status') == 'made' and finite(value):
            values.append(value)
    return dict(samples=len(values), median=median(values) if values else None)


def calibrate(rows, mode, run_id):
    """One replacement batch is one analysis; never pool old/reanalyzed runs."""
    calibration = calibration_from_rows(rows)
    result = []
    for row in rows:
        evidence = evidence_dict(row.get('evidence_json'))
        saved = evidence_dict(evidence_dict(evidence_dict(evidence.get('rim_check')).get('experiment')).get('net_calibration'))
        current = saved if saved.get('scope') == 'analysis_run_baseline_made' else calibration
        evidence.update(tier_calibration=current, analysis_run_id=run_id, analysis_mode=mode)
        result.append({**row, 'evidence_json': json.dumps(evidence, ensure_ascii=False)})
    return result


def filter_candidates(candidates, tiers=None, tags=None):
    if tiers is not None and (not isinstance(tiers, list) or any(not isinstance(t, str) or t not in TIERS for t in tiers)):
        raise ValueError('INVALID_TIERS')
    if tags is not None and (not isinstance(tags, list) or any(not isinstance(t, str) or not t for t in tags)):
        raise ValueError('INVALID_TAGS')
    return [c for c in candidates if (tiers is None or c['tier'] in tiers)
            and (tags is None or {tag['id'] for tag in c.get('tags', [])}.intersection(tags))]
