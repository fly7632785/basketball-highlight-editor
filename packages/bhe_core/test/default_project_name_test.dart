import 'package:bhe_core/bhe_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final date = DateTime(2026, 11, 6);
  for (final file in [
    'c0a80123-1234-4123-8123-123456789abc.mp4',
    '1a679f6da94cdb5f52d5381d2c.mp4',
    'IMG_0001.mp4',
    'image_1793960471.mp4',
  ]) {
    test('$file uses localized date name', () {
      expect(
        defaultProjectName(fileName: file, createdAt: date, locale: 'en'),
        'Game · Nov 6, 2026',
      );
      expect(
        defaultProjectName(fileName: file, createdAt: date, locale: 'zh'),
        '比赛 · 2026年11月6日',
      );
    });
  }
  test('keeps readable names and numbers same-day collisions', () {
    expect(
      defaultProjectName(
        fileName: 'Lakers vs Bulls.mp4',
        createdAt: date,
        locale: 'en',
      ),
      'Lakers vs Bulls',
    );
    expect(
      defaultProjectName(
        fileName: 'IMG_0001.mp4',
        createdAt: date,
        locale: 'en',
        existingNames: ['Game · Nov 6, 2026'],
      ),
      'Game · Nov 6, 2026 (2)',
    );
  });
  test('missing capture date uses Project N even when now is fixed', () {
    expect(
      defaultProjectName(
        fileName: 'IMG_0001.mp4',
        createdAt: null,
        locale: 'en',
        now: date,
      ),
      'Project 1',
    );
    expect(
      defaultProjectName(
        fileName: 'IMG_0002.mp4',
        createdAt: null,
        locale: 'en',
        existingNames: ['Project 1'],
        now: date,
      ),
      'Project 2',
    );
  });
  test('export filename sanitizes path separators and punctuation', () {
    expect(safeFileName('Game/Nov:6'), 'Game-Nov-6');
  });
}
