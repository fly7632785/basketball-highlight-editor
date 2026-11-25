import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePortraitMedia {
  static const channel = MethodChannel('com.bhe.bhe/mobile_media');

  final calls = <MethodCall>[];
  final enteredSample = Completer<void>();
  Completer<void>? holdSample;
  Completer<void>? holdRender;
  final enteredRender = Completer<void>();
  int? failAtMs;
  String? failMergeGroup;
  bool? isHdr = false;

  void install() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(channel, handle);

  void close() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null);

  Iterable<MethodCall> callsTo(String method) =>
      calls.where((call) => call.method == method);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments as Map?;
    switch (call.method) {
      case 'videoMetadata':
        return {if (isHdr != null) 'isHdr': isHdr};
      case 'sampleBallTrack':
        if (!enteredSample.isCompleted) enteredSample.complete();
        final gate = holdSample;
        if (gate != null) {
          await gate.future;
          if (callsTo('cancelExport').isNotEmpty) {
            throw PlatformException(code: 'EXPORT_CANCELLED');
          }
        }
        final start = args!['startMs'] as int;
        final end = args['endMs'] as int;
        return {
          'frameWidth': 1920,
          'frameHeight': 1080,
          'samples': [
            for (var t = start; t < end; t += 100)
              {
                'tMs': t,
                'balls': [
                  if (start != 1000)
                    {'cx': 1100.0, 'cy': 460.0, 'w': 22, 'h': 22, 'conf': .9},
                ],
                'rims': [
                  {'cx': 1200, 'cy': 460, 'w': 70, 'h': 30, 'conf': .9},
                ],
              },
          ],
        };
      case 'cancelExport':
        final gate = holdSample;
        if (gate != null && !gate.isCompleted) gate.complete();
        return null;
      case 'registerMergeExport':
        return true;
      case 'releaseMergeExport':
        return null;
      case 'exportClip':
      case 'exportPortraitClip':
      case 'mergeClips':
        if (call.method == 'exportPortraitClip') {
          if (!enteredRender.isCompleted) enteredRender.complete();
          await holdRender?.future;
        }
        if (call.method == 'exportPortraitClip' &&
            args!['startMs'] == failAtMs) {
          throw PlatformException(
            code: 'EXPORT_FAILED',
            message: 'No space left',
          );
        }
        if (call.method == 'mergeClips') {
          final clips = (args!['clips'] as List).cast<Map>();
          if (args['inputPath'] == null) {
            for (final clip in clips) {
              expect(clip['startMs'], 0);
              expect(File(clip['inputPath'] as String).existsSync(), isTrue);
            }
          }
          if (args['batchGroup']?.toString() == failMergeGroup &&
              failMergeGroup != null) {
            throw PlatformException(
              code: 'EXPORT_FAILED',
              message: 'muxer failed',
            );
          }
        }
        final path = args!['outputPath'] as String;
        File(path).writeAsStringSync('fake ${call.method}');
        return {'outputPath': path, 'committed': call.method == 'mergeClips'};
      default:
        throw MissingPluginException(call.method);
    }
  }
}
