part of '../../media_bridge.dart';

enum PortraitExportStep { sample, plan, render, merge }

class PortraitExportProgress extends ExportProgress {
  const PortraitExportProgress({
    required super.progress,
    required this.step,
    required this.clipIndex,
    required this.clipCount,
    required this.eventMs,
    super.outputPath,
    super.skippedAudioTracks,
    super.committed,
    this.clipsWithoutBall = const [],
  }) : super(message: '正在导出竖屏视频');

  final PortraitExportStep step;
  final int clipIndex, clipCount;
  final int? eventMs;
  final List<String> clipsWithoutBall;
}

NativeExportResult _decodePortraitExport(Object? raw, String outputPath) {
  final path = raw is Map ? raw['outputPath'] : raw;
  if (path is! String || path.isEmpty) {
    throw const FormatException(
      'Native portrait export returned no output path',
    );
  }
  return NativeExportResult.decode(raw, outputPath);
}

extension NativePortraitExport on NativeMediaExportEngine {
  Stream<ExportProgress> exportPortrait({
    required VideoInfo video,
    required List<Candidate> candidates,
    required String outputDirectory,
    Roi? rim,
    String projectName = 'Project',
    String? mergedPath,
    int? batchGroup,
  }) async* {
    if (candidates.isEmpty) return;
    final batch = batchGroup == null ? null : _mergeBatch;
    if (batchGroup != null && batch == null) {
      throw StateError('No active portrait merge batch');
    }

    final lease = batch ?? _MergeBatchLease(_ExportGate.enter(), _ExportRun());
    final run = lease.run;
    _activeRun = run;
    final merging = mergedPath != null;
    final clipsWithoutBall = <String>[];
    final skippedAudio = <SkippedAudioTrack>[];
    final rendered = <String>[];
    final total = candidates.length;
    final steps = 3 * total + (merging ? 1 : 0);
    Directory? staging;
    try {
      if (batch == null) {
        if (lease.ticket.waiting) {
          yield const ExportProgress(progress: 0, message: '正在结束上一次导出');
        }
        await _waitForTurn(lease.ticket, run);
      }
      if (merging) {
        staging = await Directory.systemTemp.createTemp('bhe_portrait_');
      }
      final directory = staging?.path ?? outputDirectory;
      final runId = 'portrait-${DateTime.now().microsecondsSinceEpoch}';
      for (final (index, candidate) in candidates.indexed) {
        final clipStep = 3 * index;
        final exportId = '$runId-${index + 1}';
        final path =
            '$directory/${clipFileName(index + 1, candidate, projectName: projectName)}';
        final range = {
          'inputPath': video.path,
          'startMs': candidate.startMs,
          'endMs': candidate.endMs,
          'exportId': exportId,
          'clipIndex': index + 1,
          'eventMs': candidate.eventMs,
          'sourceDurationMs': video.durationMs,
        };
        run.mergeId = null;
        run.portraitId = exportId;
        yield PortraitExportProgress(
          progress: clipStep / steps,
          step: PortraitExportStep.sample,
          clipIndex: index + 1,
          clipCount: total,
          eventMs: candidate.eventMs,
        );
        _checkPortraitCancelled(run);
        run.nativeId = exportId;
        run.nativeGeneration++;
        Map<String, Object?>? raw;
        await for (final event in _portraitStageEvents(
          run,
          'sampling',
          () => Stream.fromFuture(
            NativeMediaExportEngine._channel.invokeMapMethod<String, Object?>(
              'sampleBallTrack',
              {...range, 'sampleHz': PortraitPlanner.sampleHz},
            ),
          ),
        )) {
          if (event.fraction case final fraction?) {
            yield PortraitExportProgress(
              progress: (clipStep + fraction) / steps,
              step: PortraitExportStep.sample,
              clipIndex: index + 1,
              clipCount: total,
              eventMs: candidate.eventMs,
            );
          } else {
            raw = event.value;
          }
        }
        yield PortraitExportProgress(
          progress: (clipStep + 1) / steps,
          step: PortraitExportStep.plan,
          clipIndex: index + 1,
          clipCount: total,
          eventMs: candidate.eventMs,
        );
        _checkPortraitCancelled(run);
        final plan = _decodePortraitTrack(raw, candidate, rim);
        yield PortraitExportProgress(
          progress: (clipStep + 2) / steps,
          step: PortraitExportStep.render,
          clipIndex: index + 1,
          clipCount: total,
          eventMs: candidate.eventMs,
        );
        _checkPortraitCancelled(run);
        run.nativeGeneration++;
        Object? rawOutput;
        await for (final event in _portraitStageEvents(
          run,
          'encoding',
          () => Stream.fromFuture(
            NativeMediaExportEngine._channel.invokeMethod<Object?>(
              'exportPortraitClip',
              {
                ...range,
                'outputPath': path,
                'outWidth': 1080,
                'outHeight': 1920,
                'keyframes': [
                  for (final frame in plan.keyframes)
                    {'tMs': frame.tMs, 'cxNorm': frame.cxNorm},
                ],
              },
            ),
          ),
        )) {
          if (event.fraction case final fraction?) {
            yield PortraitExportProgress(
              progress: (clipStep + 2 + fraction) / steps,
              step: PortraitExportStep.render,
              clipIndex: index + 1,
              clipCount: total,
              eventMs: candidate.eventMs,
            );
          } else {
            rawOutput = event.value;
          }
        }
        final result = _decodePortraitExport(rawOutput, path);
        if (!plan.hasBallTrack) clipsWithoutBall.add(candidate.id);
        if (merging) {
          rendered.add(result.path);
          skippedAudio.addAll(result.skippedAudioTracks);
        } else {
          yield PortraitExportProgress(
            progress: (clipStep + 3) / steps,
            step: PortraitExportStep.render,
            clipIndex: index + 1,
            clipCount: total,
            eventMs: candidate.eventMs,
            outputPath: result.path,
            skippedAudioTracks: result.skippedAudioTracks,
            clipsWithoutBall: plan.hasBallTrack ? const [] : [candidate.id],
          );
        }
        // Native success already published this file. Record it before
        // honoring a late cancellation or starting any other clip.
        _checkPortraitCancelled(run);
      }

      if (mergedPath != null) {
        run.portraitId = null;
        yield PortraitExportProgress(
          progress: 3 * total / steps,
          step: PortraitExportStep.merge,
          clipIndex: total,
          clipCount: total,
          eventMs: null,
        );
        _checkPortraitCancelled(run);
        await for (final event in _portraitStageEvents(
          run,
          'merging',
          () => _mergeClips(
            video: video,
            candidates: candidates,
            outputPath: mergedPath,
            lease: lease,
            batchGroup: batchGroup,
            renderedPaths: rendered,
          ),
        )) {
          if (event.fraction case final fraction?) {
            yield PortraitExportProgress(
              progress: (3 * total + fraction) / steps,
              step: PortraitExportStep.merge,
              clipIndex: total,
              clipCount: total,
              eventMs: null,
            );
            continue;
          }
          final update = event.value!;
          if (update.outputPath == null) continue;
          yield PortraitExportProgress(
            progress: 1,
            step: PortraitExportStep.merge,
            clipIndex: total,
            clipCount: total,
            eventMs: null,
            outputPath: update.outputPath,
            skippedAudioTracks: [...skippedAudio, ...update.skippedAudioTracks],
            committed: update.committed,
            clipsWithoutBall: List.unmodifiable(clipsWithoutBall),
          );
        }
      }
    } on MissingPluginException catch (error, stack) {
      MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'export.portrait',
      );
      throw const MobileExportException('当前平台尚未接入竖屏导出。');
    } on PlatformException catch (error, stack) {
      MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'export.portrait',
      );
      throw MobileDiagnosticException(error, 'export.portrait');
    } finally {
      try {
        if (staging != null && !lease.uncertain) {
          await staging.delete(recursive: true);
        }
      } finally {
        if (batch == null) {
          if (!lease.uncertain) lease.ticket.finish();
          if (identical(_activeRun, run)) _activeRun = null;
        }
      }
    }
  }
}

Stream<({T? value, double? fraction})> _portraitStageEvents<T>(
  _ExportRun run,
  String stage,
  Stream<T> Function() start,
) async* {
  final channel = NativeMediaExportEngine._channel;
  final events = StreamController<({T? value, double? fraction})>();
  var lastFraction = 0.0;
  channel.setMethodCallHandler((call) async {
    final args = call.arguments;
    if (call.method != 'exportProgress' ||
        args is! Map ||
        run.cancelled ||
        run.nativeId == null ||
        args['exportId'] != run.nativeId ||
        args['stage'] != stage ||
        events.isClosed) {
      return;
    }
    final value = args['progress'];
    if (value is num && value.isFinite && value > lastFraction && value < 1) {
      lastFraction = value.toDouble();
      events.add((value: null, fraction: lastFraction));
    }
  });
  final drain = () async {
    try {
      await for (final value in start()) {
        events.add((value: value, fraction: null));
      }
    } on Object catch (error, stack) {
      events.addError(error, stack);
    } finally {
      unawaited(events.close());
    }
  }();
  try {
    yield* events.stream;
  } finally {
    // Unsubscribing cannot release the export gate while the file is in use.
    await drain;
    channel.setMethodCallHandler(null);
  }
}

void _checkPortraitCancelled(_ExportRun run) {
  if (run.cancelled) throw const MobileExportException('导出已取消');
}

PortraitPlan _decodePortraitTrack(
  Map<String, Object?>? raw,
  Candidate candidate,
  Roi? rim,
) {
  if (raw == null ||
      raw['frameWidth'] is! int ||
      raw['frameHeight'] is! int ||
      raw['samples'] is! List) {
    throw const FormatException('Invalid native ball tracking result');
  }
  List<PortraitDetection> boxes(Object? value) => [
    for (final item in value as List)
      PortraitDetection(
        cx: (item['cx'] as num).toDouble(),
        cy: (item['cy'] as num).toDouble(),
        w: (item['w'] as num).toDouble(),
        h: (item['h'] as num).toDouble(),
        conf: (item['conf'] as num).toDouble(),
      ),
  ];
  return PortraitPlanner.plan(
    frameWidth: raw['frameWidth'] as int,
    frameHeight: raw['frameHeight'] as int,
    startMs: candidate.startMs,
    endMs: candidate.endMs,
    eventMs: candidate.reason == 'manual' ? null : candidate.eventMs,
    eventRim: rim,
    samples: [
      for (final sample in raw['samples'] as List)
        PortraitTrackSample(
          tMs: sample['tMs'] as int,
          balls: boxes(sample['balls']),
          rims: boxes(sample['rims']),
        ),
    ],
  );
}
