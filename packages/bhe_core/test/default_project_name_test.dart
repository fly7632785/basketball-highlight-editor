import 'package:bhe_core/bhe_core.dart';
import 'package:test/test.dart';

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
  // L232 ③：读不到拍摄时间 → 用导入日期（不再有 "Project N"）。
  test('missing capture date uses the import date', () {
    expect(
      defaultProjectName(
        fileName: 'IMG_0001.mp4',
        createdAt: null,
        locale: 'en',
        now: date,
      ),
      'Game · Nov 6, 2026',
    );
    expect(
      defaultProjectName(
        fileName: 'IMG_0002.mp4',
        createdAt: null,
        locale: 'en',
        existingNames: ['Game · Nov 6, 2026'],
        now: date,
      ),
      'Game · Nov 6, 2026 (2)',
    );
  });
  test('export filename sanitizes path separators and punctuation', () {
    expect(safeFileName('Game/Nov:6'), 'Game-Nov-6');
  });

  // L232 ③：读不到拍摄时间时改用导入日期，不再出现「项目 N」。
  test('no capture date falls back to import date, not Project N', () {
    final name = defaultProjectName(
      fileName: 'image_30CA7383-7EE6-4F7A-9A2B-1793960471.mp4',
      locale: 'en',
      now: DateTime(2026, 11, 10),
    );
    expect(name, 'Game · Nov 10, 2026');
    expect(name.contains('Project'), isFalse);
  });

  test('same fallback date gets a numeric suffix', () {
    final name = defaultProjectName(
      fileName: 'image_30CA7383-7EE6-4F7A-9A2B-1793960471.mp4',
      locale: 'zh',
      now: DateTime(2026, 11, 10),
      existingNames: const ['比赛 · 2026年11月10日'],
    );
    expect(name, '比赛 · 2026年11月10日 (2)');
  });

  test('explicit fallback flag is accepted for import-date naming', () {
    final name = defaultProjectName(
      fileName: 'IMG_0001.mp4',
      locale: 'en',
      createdAt: DateTime(2026, 11, 10),
      createdAtIsFallback: true,
      existingNames: const [],
    );
    expect(name, 'Game · Nov 10, 2026');
  });
}
