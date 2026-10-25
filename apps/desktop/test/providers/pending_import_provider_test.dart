import 'package:desktop/providers/pending_import_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts supported video extensions regardless of case', () {
    for (final path in ['/v/a.mp4', '/v/b.MOV', '/v/c.m4v', 'C:\\v\\d.Avi', '/v/e.mkv']) {
      expect(isImportableVideo(path), isTrue, reason: path);
    }
    for (final path in ['/v/a.mp3', '/v/notes.txt', '/v/no_extension', '/v/.mp4.bak']) {
      expect(isImportableVideo(path), isFalse, reason: path);
    }
  });

  test('dropped paths are handed over once', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(pendingImportProvider.notifier);
    notifier.set(['/v/part1.mp4', '/v/part2.mp4']);
    expect(notifier.take(), ['/v/part1.mp4', '/v/part2.mp4']);
    expect(notifier.take(), isNull);
    expect(container.read(pendingImportProvider), isNull);
  });
}
