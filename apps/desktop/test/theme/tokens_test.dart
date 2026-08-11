// test/theme/tokens_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/theme/tokens.dart';

void main() {
  test('spacing is 8-multiple scale', () {
    expect(Spacing.xs, 4);
    expect(Spacing.sm, 8);
    expect(Spacing.md, 16);
    expect(Spacing.lg, 24);
    expect(Spacing.xl, 32);
    expect(Spacing.xxl, 48);
  });
  test('breakpoints match spec', () {
    expect(Breakpoints.md, 900);
    expect(Breakpoints.lg, 1280);
  });
  test('durations within Linear range', () {
    expect(DurationD.fast.inMilliseconds, 150);
    expect(DurationD.normal.inMilliseconds, 220);
    expect(DurationD.slow.inMilliseconds, 320);
  });
}
