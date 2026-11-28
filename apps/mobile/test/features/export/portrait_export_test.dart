import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/export/export_modes.dart';
import 'package:bhe_mobile/features/review_tiers/mobile_tiers.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_portrait_media.dart';
import '../../support/mobile_video_fixture.dart';

const _first = Candidate(
  id: 'first',
  startMs: 1000,
  endMs: 3000,
  eventMs: 2000,
  players: ['Alice', 'Bob'],
  reviewed: true,
);
const _second = Candidate(
  id: 'second',
  startMs: 3100,
  endMs: 5100,
  eventMs: 4000,
  players: ['Bob'],
  reviewed: true,
);
const _uncertain = Candidate(
  id: 'uncertain',
  startMs: 5500,
  endMs: 7500,
  eventMs: 6500,
  players: ['Alice'],
);
const _goals = ExportScope.anyTag(tiers: {MobileTier.goal});
const _portrait = ExportFraming.portrait916;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MobileVideoFixture fixture;
  late FakePortraitMedia media;

  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
    media = FakePortraitMedia()..install();
    final source = await fixture.file('original.mp4', 'original');
    fixture.state.project = fixture
        .project(source.path)
        .copyWith(
          candidates: [_second, _first, _uncertain],
          players: ['Alice', 'Bob'],
        );
  });

  tearDown(() async {
    media.close();
    await fixture.close();
  });

  test(
    'portrait requests use the agreed channel and absolute keyframes',
    () async {
      await fixture.state.exportClipsInScope(
        const ExportScope.only({'Alice'}, tiers: {MobileTier.goal}),
        framing: _portrait,
      );
      final sample = media.callsTo('sampleBallTrack').single.arguments as Map;
      final render =
          media.callsTo('exportPortraitClip').single.arguments as Map;
      expect(sample['sampleHz'], 10);
      expect(sample['startMs'], _first.startMs);
      expect(sample['endMs'], _first.endMs);
      for (final request in [sample, render]) {
        expect(request['clipIndex'], 1);
        expect(request['eventMs'], _first.eventMs);
        expect(request['sourceDurationMs'], 10000);
      }
      expect(sample['exportId'], render['exportId']);
      expect(render['inputPath'], fixture.state.project.video!.path);
      expect(render['outWidth'], 1080);
      expect(render['outHeight'], 1920);
      final frames = (render['keyframes'] as List).cast<Map>();
      expect(frames.first['tMs'], _first.startMs);
      expect(frames.last['tMs'], _first.endMs);
      expect(frames.first['cxNorm'], closeTo(.625, .001));
      expect(fixture.state.portraitNoBallCount, 1);
      expect(fixture.state.project.exportHistory.single.files, hasLength(1));
    },
  );

  test('portrait follows the ball at the event and calibrated rim', () async {
    const clip = Candidate(
      id: 'shot',
      startMs: 1000,
      endMs: 8500,
      eventMs: 4000,
      reviewed: true,
    );
    fixture.state.project = fixture.state.project.copyWith(
      candidates: [clip],
      rimRoi: const Roi(left: .27, top: .375, right: .30, bottom: .42),
    );
    Map<String, num> box(
      double x,
      double y,
      double confidence, {
      int width = 24,
      int height = 24,
    }) => {'cx': x, 'cy': y, 'w': width, 'h': height, 'conf': confidence};
    const descent = {
      3800: 387.0,
      3900: 401.0,
      4000: 414.0,
      4100: 431.0,
      4200: 446.0,
    };
    media.portraitSamples = [
      for (var t = 1000; t < 8500; t += 100)
        {
          'tMs': t,
          'balls': [
            box(1350, descent[t - 600] ?? 560, .98),
            if (t < 4900 || t >= 6300)
              box(550, descent[t] ?? (t < 4000 ? 370 : 460), .7),
          ],
          'rims': [
            box(1350, 425, .95, width: 60, height: 50),
            box(550, 425, .85, width: 60, height: 50),
          ],
        },
    ];
    await fixture.state.exportClipsInScope(_goals, framing: _portrait);
    final render = media.callsTo('exportPortraitClip').single.arguments as Map;
    final frames = (render['keyframes'] as List).cast<Map>();
    expect(
      frames.map((frame) => frame['cxNorm'] as double),
      everyElement(lessThan(.4)),
    );
  });

  test(
    'portrait export forwards a candidate at and past the source tail',
    () async {
      const tail = Candidate(
        id: 'tail',
        startMs: 9800,
        endMs: 10200,
        eventMs: 9983,
        players: ['Alice'],
        reviewed: true,
      );
      fixture.state.project = fixture.state.project.copyWith(
        candidates: [tail],
      );
      await fixture.state.exportClipsInScope(_goals, framing: _portrait);
      for (final method in ['sampleBallTrack', 'exportPortraitClip']) {
        final args = media.callsTo(method).single.arguments as Map;
        expect(args['clipIndex'], 1);
        expect(args['sourceDurationMs'], 10000);
        expect(args['startMs'], 9800);
        expect(args['eventMs'], 9983);
        expect(args['endMs'], 10200);
      }
    },
  );

  test('merge uses only rendered files in source time order', () async {
    await fixture.state.mergeClipsInScope(_goals, framing: _portrait);
    expect(
      media.callsTo('exportPortraitClip').map((c) => c.arguments['startMs']),
      [1000, 3100],
    );
    final merge = media.callsTo('mergeClips').single.arguments as Map;
    final paths = (merge['clips'] as List)
        .map((clip) => clip['inputPath'] as String)
        .toList();
    expect(merge['inputPath'], isNull);
    expect(
      paths,
      media.callsTo('exportPortraitClip').map((c) => c.arguments['outputPath']),
    );
    expect(paths.every((path) => !File(path).existsSync()), isTrue);
    expect(fixture.state.exportedPaths, hasLength(1));
    expect(fixture.state.portraitNoBallCount, 1);
  });

  test(
    'a failed label merge preserves the prior group and counts its unique clips',
    () async {
      media.failMergeGroup = '2';
      await fixture.state.exportByLabels(scope: _goals, framing: _portrait);
      expect(fixture.state.exportBatchFiles, hasLength(1));
      expect(fixture.state.exportedPaths, hasLength(1));
      expect(File(fixture.state.exportedPaths.single).existsSync(), isTrue);
      expect(fixture.state.portraitNoBallCount, 1);
      expect(fixture.state.project.exportHistory.single.files, hasLength(1));
      expect(fixture.state.errorMessage, isNotNull);
    },
  );

  test(
    'retry as original makes no further portrait calls and keeps prior files',
    () async {
      media.failAtMs = 3100;
      fixture.state.project = fixture.state.project.copyWith(
        candidates: [_first, _second, _uncertain],
      );
      await fixture.state.exportClipsInScope(
        ExportScope.all,
        framing: _portrait,
      );
      expect(media.callsTo('sampleBallTrack'), hasLength(2));
      final partial = fixture.state.exportedPaths.single;
      expect(fixture.state.project.exportHistory.single.files, hasLength(1));
      expect(fixture.state.errorMessage, '手机存储空间不足，请清理后重试。');
      await fixture.state.exportClipsInScope(ExportScope.all);
      expect(media.callsTo('exportClip'), hasLength(3));
      expect(media.callsTo('sampleBallTrack'), hasLength(2));
      expect(File(partial).existsSync(), isTrue);
      expect(fixture.state.portraitNoBallCount, 0);
    },
  );

  test('HDR uses the same portrait requests as SDR', () async {
    final project = fixture.state.project;
    fixture.state.project = project.copyWith(
      video: VideoInfo.fromJson({...project.video!.toJson(), 'is_hdr': true}),
    );
    await fixture.state.exportClipsInScope(_goals, framing: _portrait);
    expect(media.callsTo('sampleBallTrack'), hasLength(2));
    expect(media.callsTo('exportPortraitClip'), hasLength(2));
    expect(fixture.state.exportedPaths, hasLength(2));
    expect(fixture.state.errorMessage, isNull);
  });

  test('cancels the active sampling request before rendering', () async {
    media.holdSample = Completer<void>();
    final run = fixture.state.exportClipsInScope(_goals, framing: _portrait);
    await media.enteredSample.future;
    await fixture.state.cancelExport();
    await run;
    final sample = media.callsTo('sampleBallTrack').single.arguments as Map;
    final cancel = media.callsTo('cancelExport').single.arguments as Map;
    expect(cancel['exportId'], sample['exportId']);
    expect(media.callsTo('exportPortraitClip'), isEmpty);
    expect(fixture.state.exportedPaths, isEmpty);
    expect(fixture.state.exportCancelled, isTrue);
  });
  test(
    'native portrait progress reaches only the matching active stage',
    () async {
      media.holdRender = Completer<void>();
      final progress = <double>[];
      final steps = <PortraitExportStep>{};
      fixture.state.addListener(() {
        final update = fixture.state.portraitProgress;
        if (update == null) return;
        steps.add(update.step);
        if (update.step == PortraitExportStep.render) {
          progress.add(update.progress);
        }
      });
      final run = fixture.state.exportClipsInScope(
        const ExportScope.only({'Alice'}, tiers: {MobileTier.goal}),
        framing: _portrait,
      );
      await media.enteredRender.future;
      final id = media
          .callsTo('exportPortraitClip')
          .single
          .arguments['exportId'];
      Future<void> send(Object exportId, String stage, double fraction) async {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              FakePortraitMedia.channel.name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall('exportProgress', {
                  'exportId': exportId,
                  'stage': stage,
                  'progress': fraction,
                }),
              ),
              (_) {},
            );
      }

      await send('previous-job', 'encoding', .25);
      await send(id, 'sampling', .25);
      await send(id, 'encoding', .5);
      await send(id, 'encoding', .25);
      media.holdRender!.complete();
      await run;
      expect(steps, {
        PortraitExportStep.sample,
        PortraitExportStep.plan,
        PortraitExportStep.render,
      });
      expect(progress, contains(2.5 / 3));
      expect(progress, isNot(contains(2.25 / 3)));
    },
  );

  test('a completed render stays in history after a late cancel', () async {
    media.holdRender = Completer<void>();
    final run = fixture.state.exportClipsInScope(_goals, framing: _portrait);
    await media.enteredRender.future;
    await fixture.state.cancelExport();
    media.holdRender!.complete();
    await run;
    expect(media.callsTo('sampleBallTrack'), hasLength(1));
    expect(fixture.state.exportedPaths, hasLength(1));
    expect(File(fixture.state.exportedPaths.single).existsSync(), isTrue);
    expect(fixture.state.project.exportHistory.single.files, hasLength(1));
  });
}
