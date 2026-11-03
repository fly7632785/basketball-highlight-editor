import 'dart:async';

import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

FilePickerResult chooseFile(String name, {String? path}) =>
    FilePickerResult([PlatformFile(name: name, path: path, size: 4)]);

/// 只收集日志的替身后端，避免测试碰原生通道。
class LogBackend implements DiagnosticBackend {
  final messages = <String>[];
  @override
  Future<void> initialize(String v, String l) async {}
  @override
  Future<void> append(String m, String? k) async => messages.add(m);
  @override
  Future<DiagnosticSnapshot> snapshot() async =>
      DiagnosticSnapshot(lines: messages, available: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('占用中重复调用只开一次窗口，且占用状态会复位', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final gate = Completer<FilePickerResult?>();
      f.picker.waits.add(gate);
      final first = f.state.pickVideo();
      final busyDuringPick = f.state.pickerBusy;
      // 第二次点击：直接忽略，不进入选择、不报错。
      await f.state.pickVideo();
      await f.state.createNewProjectAndPickVideo();
      expect(f.picker.calls, 1);
      gate.complete(null);
      await first;
      expect(f.state.pickerBusy, isFalse);
      expect(f.state.diagnosticError, isNull);
      expect(busyDuringPick, isTrue);
    } finally {
      await f.close();
    }
  });

  test('取消（返回 null）与成功都会复位占用状态', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      f.choose(null);
      await f.state.pickVideo();
      expect(f.state.pickerBusy, isFalse);
      final video = await f.file('clip.mp4', 'video-bytes');
      f.choose(video);
      await f.state.pickVideo();
      expect(f.state.pickerBusy, isFalse);
      expect(f.picker.calls, 2);
    } finally {
      await f.close();
    }
  });

  test('第一次 already_active、第二次成功：拿到结果且恰好调用两次', () async {
    final f = MobileVideoFixture();
    await f.init(pickerRetryDelay: Duration.zero);
    try {
      final backend = LogBackend();
      final previous = MobileDiagnostics.instance;
      MobileDiagnostics.instance = MobileDiagnostics(backend);
      try {
        final video = await f.file('clip.mp4', 'video-bytes');
        var attempt = 0;
        f.picker.pick = () async {
          attempt++;
          if (attempt == 1) {
            throw PlatformException(
              code: 'already_active',
              message: 'File picker is already active',
            );
          }
          return chooseFile('clip.mp4', path: video.path);
        };
        await f.state.pickVideo();
        expect(f.picker.calls, 2);
        expect(f.state.pickerBusy, isFalse);
        expect(f.state.project.video, isNotNull);
        expect(
          backend.messages.any((m) => m.contains('picker.retry.video')),
          isTrue,
          reason: '重试要记一条「第二次」日志',
        );
      } finally {
        MobileDiagnostics.instance = previous;
      }
    } finally {
      await f.close();
    }
  });

  test('两次都 already_active：不再重试、给出人话提示、状态复位', () async {
    final f = MobileVideoFixture();
    await f.init(pickerRetryDelay: Duration.zero);
    try {
      f.picker.pick = () async => throw PlatformException(
        code: 'already_active',
        message: 'File picker is already active',
      );
      await f.state.pickVideo();
      expect(f.picker.calls, 2, reason: '只重试一次');
      expect(f.state.pickerBusy, isFalse);
      expect(
        f.state.errorMessage,
        contains('系统文件选择窗口还在占用'),
      );
    } finally {
      await f.close();
    }
  });

  test('其它异常不被吞掉', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      f.picker.pick = () async =>
          throw PlatformException(code: 'some_other_failure', message: 'boom');
      await f.state.pickVideo();
      expect(f.picker.calls, 1, reason: '非 already_active 不重试');
      expect(f.state.pickerBusy, isFalse);
      expect(f.state.errorMessage, isNotNull);
      expect(f.state.diagnosticError, isNotNull);
    } finally {
      await f.close();
    }
  });
}
