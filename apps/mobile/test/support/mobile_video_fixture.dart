import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestFilePicker extends FilePicker {
  /// 可以同时挂多个「待完成的窗口」：先挂的先被调用（FIFO）。
  final waits = <Completer<FilePickerResult?>>[];
  Future<FilePickerResult?> Function()? pick;
  var calls = 0;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    if (waits.isNotEmpty) return waits.removeAt(0).future;
    return pick?.call();
  }
}

class MobileVideoFixture {
  late Directory root;
  late MobileAppState state;
  final picker = TestFilePicker();
  Directory get data => Directory('${root.path}/BHE Mobile');

  Future<void> init({
    Future<VideoInfo> Function(File)? probe,
    MobileAnalysisEngine? engine,
    MobileExportEngine? exportEngine,
    Duration exportCancelTimeout = const Duration(seconds: 5),
    Duration exportDrainTimeout = const Duration(seconds: 30),
    Duration analysisStartupTimeout = const Duration(seconds: 60),
    Duration analysisCancelTimeout = const Duration(seconds: 6),
    Duration pickerRetryDelay = const Duration(milliseconds: 1500),
  }) async {
    root = await Directory.systemTemp.createTemp('bhe_state_');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    FilePicker.platform = picker;
    state = MobileAppState(
      // 走注入的文件选择器（picker 本身就是 file_picker 的替身）。
      filePicker: ({
        required FileType type,
        List<String>? allowedExtensions,
      }) => picker.pickFiles(type: type, allowedExtensions: allowedExtensions),
      analysisEngine: engine ?? const MobileAnalysisEngineUnavailable(),
      exportEngine: exportEngine,
      exportCancelTimeout: exportCancelTimeout,
      exportDrainTimeout: exportDrainTimeout,
      videoProbe: probe ?? inspect,
      analysisStartupTimeout: analysisStartupTimeout,
      analysisCancelTimeout: analysisCancelTimeout,
      pickerRetryDelay: pickerRetryDelay,
    );
    await state.ready;
  }

  static Future<VideoInfo> inspect(File file) async => VideoInfo(
    path: file.path,
    name: 'original.mp4',
    sizeBytes: await file.length(),
    durationMs: 10000,
    width: 1920,
    height: 1080,
    sha256: await file.readAsString(),
  );

  Future<File> file(String relative, String contents) async {
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    return file.writeAsString(contents);
  }

  ProjectSnapshot project(String path, {String id = 'A'}) => ProjectSnapshot(
    id: id,
    name: id,
    video: VideoInfo(
      path: path,
      name: 'original.mp4',
      sizeBytes: 8,
      durationMs: 10000,
      width: 1920,
      height: 1080,
      sha256: 'original',
    ),
    hoopRoi: const Roi(left: .2, top: .2, right: .6, bottom: .6),
    netRoi: const Roi(left: .3, top: .3, right: .5, bottom: .5),
    players: const ['Alice'],
    candidates: const [
      Candidate(
        id: 'goal',
        startMs: 1000,
        endMs: 3000,
        eventMs: 2000,
        player: 'Alice',
        reviewed: true,
        rangeEdited: true,
      ),
    ],
  );

  void choose(File? file) {
    picker.pick = () async => file == null
        ? null
        : FilePickerResult([
            PlatformFile(
              name: file.uri.pathSegments.last,
              path: file.path,
              size: await file.length(),
            ),
          ]);
  }

  Future<void> close({bool disposeState = true}) async {
    await pumpEventQueue();
    if (disposeState) state.dispose();
    FilePicker.platform = TestFilePicker();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  }
}
