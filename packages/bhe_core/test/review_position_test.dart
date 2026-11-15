import 'package:bhe_core/bhe_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'nearest clip follows the anchor, not the first or retained selection',
    () {
      expect(
        nearestReviewCandidate(
          [0, 2000, 6000, 8000],
          anchorMs: 6500,
          startMs: (t) => t,
        ),
        6000,
      );
      expect(
        nearestReviewCandidate(
          [0, 2000, 6000, 8000],
          anchorMs: 7900,
          startMs: (t) => t,
        ),
        8000,
      );
    },
  );
  test('equal distance prefers the earlier time even in an unsorted list', () {
    expect(
      nearestReviewCandidate(
        [8000, 0, 4000],
        anchorMs: 6000,
        startMs: (t) => t,
      ),
      4000,
    );
  });
  test('empty filter has no selection', () {
    expect(
      nearestReviewCandidate<int>([], anchorMs: 6000, startMs: (t) => t),
      isNull,
    );
  });
}
