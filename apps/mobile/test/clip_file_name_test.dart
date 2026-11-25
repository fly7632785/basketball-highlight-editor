import 'dart:convert';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const candidate = Candidate(
    id: 'candidate_12345',
    startMs: 9000,
    endMs: 15000,
    eventMs: 12345,
    confidence: .8,
  );

  test('clip file names carry the index, time and a safe player name', () {
    // L217 起导出名带项目名前缀（BHE-<项目名>-highlights-…），更新期望。
    expect(
      clipFileName(1, candidate),
      'BHE-Project-highlights-goal_001_12.35s.mp4',
    );
    expect(
      clipFileName(2, candidate.copyWith(player: '科比')),
      'BHE-Project-highlights-goal_002_12.35s_科比.mp4',
    );
    expect(
      clipFileName(3, candidate.copyWith(player: ' A/B:C*? ')),
      'BHE-Project-highlights-goal_003_12.35s_A_B_C.mp4',
    );
    expect(
      clipFileName(4, candidate.copyWith(player: '...')),
      'BHE-Project-highlights-goal_004_12.35s.mp4',
    );
  });

  for (final (label, projectName, player) in [
    ('ASCII', 'Game-${List.filled(225, 'x').join()}', ''),
    (
      'Chinese',
      '比赛-${List.filled(80, '篮').join()}',
      '${List.filled(39, '球').join()}🏀',
    ),
    (
      'emoji',
      'Game-${List.filled(55, '🏀').join()}',
      List.filled(40, '🏀').join(),
    ),
  ]) {
    test('a valid long $label source name remains writable on export', () async {
      final temp = await Directory.systemTemp.createTemp('bhe-export-name-');
      addTearDown(() => temp.delete(recursive: true));
      expect(
        defaultProjectName(fileName: '$projectName.mp4', locale: 'en'),
        projectName,
      );
      final source = File('${temp.path}/$projectName.mp4');
      expect(utf8.encode('$projectName.mp4').length, lessThanOrEqualTo(255));
      await source.writeAsString('valid source name');
      final tagged = const Candidate(
        id: 'one',
        startMs: 0,
        endMs: 2000,
        eventMs: 1000,
      ).copyWith(player: player);
      final name = clipFileName(1, tagged, projectName: projectName);
      final suffix = player.isEmpty
          ? '-highlights-goal_001_1.00s.mp4'
          : '-highlights-goal_001_1.00s_$player.mp4';
      debugPrintSynchronously(
        'source_bytes=${utf8.encode('$projectName.mp4').length}; export_bytes=${utf8.encode(name).length}',
      );
      expect(utf8.encode(name).length, lessThanOrEqualTo(255));
      expect(utf8.decode(utf8.encode(name)), name);
      expect(name, startsWith('BHE-'));
      expect(name, endsWith(suffix));
      final output = File('${temp.path}/$name');
      await output.writeAsString('export');
      expect(await output.readAsString(), 'export');
      expect(clipFileName(2, tagged, projectName: projectName), isNot(name));
    });
  }
}
