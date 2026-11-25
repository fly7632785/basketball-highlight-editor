import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ordered multi-tags and legacy first tag survive real BHE export and import',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      const share = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        share,
        (_) async => 'dev.fluttercommunity.plus/share/success',
      );
      try {
        final video = await f.file(
          'BHE Mobile/videos/A/source.mp4',
          'original',
        );
        f.state.project = f
            .project(video.path)
            .copyWith(
              players: ['Alice', 'Drew', 'Bob'],
              candidates: const [
                Candidate(
                  id: 'a',
                  startMs: 1000,
                  endMs: 2000,
                  eventMs: 1500,
                  players: ['Alice', 'Bob', 'Drew'],
                  reviewed: true,
                  note: 'kept',
                ),
                Candidate(
                  id: 'b',
                  startMs: 2000,
                  endMs: 3000,
                  eventMs: 2500,
                  players: ['Drew'],
                  selection: CandidateSelection.excluded,
                ),
              ],
            );
        expect(await f.state.renamePlayer('Alice', 'Carol'), isTrue);
        expect(await f.state.removePlayer('Drew'), isTrue);
        await f.state.exportProjectPackage();
        final package = File('${f.data.path}/A.bhe');
        expect(await package.exists(), isTrue);
        final metadata = ZipDecoder()
            .decodeBytes(await package.readAsBytes())
            .findFile('project.json')!;
        final raw = jsonDecode(utf8.decode(metadata.content)) as Map;
        expect(raw['version'], 2);
        final first = raw['manifest']['candidates'][0] as Map;
        expect(first['player'], 'Carol');
        expect(first['players'], ['Carol', 'Bob']);
        f.choose(package);
        await f.state.importProject();
        final imported = f.state.project;
        expect(imported.id, isNot('A'));
        expect(imported.players, ['Carol', 'Bob']);
        expect(imported.candidates[0].players, ['Carol', 'Bob']);
        expect(imported.candidates[0].note, 'kept');
        expect(imported.candidates[0].reviewed, isTrue);
        expect(imported.candidates[1].player, isNull);
        expect(imported.candidates[1].selection, CandidateSelection.excluded);
        expect(await File(imported.video!.path).readAsString(), 'original');

        // A v2 package written before the list field had only the scalar.
        for (final candidate in raw['manifest']['candidates'] as List) {
          (candidate as Map).remove('players');
        }
        raw.remove('candidates');
        final old = File('${f.root.path}/legacy.bhe');
        final archive = Archive()
          ..addFile(ArchiveFile.string('project.json', jsonEncode(raw)));
        await old.writeAsBytes(ZipEncoder().encode(archive));
        f.choose(old);
        await f.state.importProject();
        expect(f.state.project.candidates.first.players, ['Carol']);
        expect(f.state.project.candidates.last.players, isEmpty);
      } finally {
        messenger.setMockMethodCallHandler(share, null);
        await f.close();
      }
    },
  );
}
