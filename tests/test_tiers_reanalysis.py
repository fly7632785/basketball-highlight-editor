"""L428r regression: nearest events cannot fall back after an old review is claimed."""
import pytest

from tests.test_tiers import project, row
from engine.python.basketball_engine.tiers import filter_candidates


@pytest.mark.parametrize('reverse_old', [False, True])
@pytest.mark.parametrize('reverse_new', [False, True])
@pytest.mark.parametrize('keep_exact_id', [False, True])
def test_reanalysis_never_inherits_second_nearest_review(
    project, reverse_old, reverse_new, keep_exact_id,
):
    _, store, video, a, b = project
    old_rows = [row('old-a', 5000), row('old-b', 7500)]
    store.replace_candidates(video['id'], old_rows[::-1] if reverse_old else old_rows)
    store.set_candidate_players('old-a', [a])
    store.review_candidate('old-a', 'goal', reason='made')
    store.update_clip_range('old-a', 4500, 5400)
    store.set_candidate_players('old-b', [b])
    store.review_candidate('old-b', 'excluded', reason='rim_out')
    store.update_clip_range('old-b', 7200, 8000)
    original = {c['id']: c for c in store.list_candidates()}

    first_id = 'old-a' if keep_exact_id else 'new-a'
    new_rows = [row(first_id, 4000), row('new-ambiguous', 6100)]
    store.replace_candidates(video['id'], new_rows[::-1] if reverse_new else new_rows)
    result = {c['id']: c for c in store.list_candidates()}
    first, ambiguous = result[first_id], result['new-ambiguous']

    assert [t['id'] for t in first['tags']] == [a]
    assert first['review_status'] == 'goal' and first['tier'] == 'must'
    assert first['reviewed_at'] == original['old-a']['reviewed_at']
    assert (first['review_start_ms'], first['review_end_ms']) == (3500, 4400)
    # 6100's closest old event is still 5000, not the now-available 7500.
    assert ambiguous['tags'] == []
    assert ambiguous['player_id'] is None
    assert ambiguous['review_status'] == 'pending'
    assert ambiguous['review_reason'] is None and ambiguous['reviewed_at'] is None
    assert ambiguous['tier'] == 'suspect' and ambiguous['tier_source'] == 'algorithm'
    assert (ambiguous['review_start_ms'], ambiguous['review_end_ms']) == (6000, 6200)
    assert {c['id'] for c in filter_candidates(list(result.values()), ['must', 'suspect'], None)} == {
        first_id, 'new-ambiguous',
    }
    print('ORDER_INDEPENDENT', reverse_old, reverse_new, keep_exact_id,
          {'first': ('goal', 'must', 1, 3500, 4400),
           'ambiguous': ('pending', 'suspect', 0, 6000, 6200)})
