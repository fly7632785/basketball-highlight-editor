import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' as selector;
import 'package:flutter/services.dart';

import 'app_log.dart';

/// 文件/目录选择入口。Windows 走 runner 的 `bhe/native_file_dialog` 通道:
/// 对话框跑在专用 STA 线程上,shell 卡死(比如半死的网络映射盘)时只会让
/// 对话框出不来,主窗口保持可操作;其他平台沿用 file_selector。
abstract class BheFileDialog {
  static const MethodChannel _channel = MethodChannel('bhe/native_file_dialog');

  /// 对话框迟迟不弹出时的逃生舱:超时后放行界面,让用户可以换路径重试。
  /// 原生对话框线程无法安全终止,超时后它会留在原地直到应用退出,无害。
  static const _windowsTimeout = Duration(seconds: 90);

  // 测试里会替换 FileSelectorPlatform.instance 来模拟选择结果,此时沿用
  // 可 mock 的 file_selector;只有生产环境的 Windows 才走原生通道。
  static bool get _useNativeChannel =>
      Platform.isWindows && Platform.environment['FLUTTER_TEST'] != 'true';

  static Future<String?> getSaveLocation({
    required String suggestedName,
    required String typeLabel,
    required List<String> extensions,
  }) async {
    if (!_useNativeChannel) {
      final location = await selector.getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: [
          selector.XTypeGroup(label: typeLabel, extensions: extensions),
        ],
      );
      return location?.path;
    }
    final result = await _invokeMap('save', {
      'suggestedName': suggestedName,
      'typeLabel': typeLabel,
      'extensions': extensions,
    });
    return result == null ? null : result['path'] as String?;
  }

  static Future<String?> getDirectoryPath({String? confirmLabel}) async {
    if (!_useNativeChannel) {
      return selector.getDirectoryPath(confirmButtonText: confirmLabel);
    }
    return _invoke<String>('directory', {'confirmLabel': confirmLabel});
  }

  static Future<selector.XFile?> openFile({
    String? confirmLabel,
    required String typeLabel,
    required List<String> extensions,
  }) async {
    if (!_useNativeChannel) {
      return selector.openFile(
        confirmButtonText: confirmLabel,
        acceptedTypeGroups: [
          selector.XTypeGroup(label: typeLabel, extensions: extensions),
        ],
      );
    }
    final path = await _invoke<String>('open', {
      'confirmLabel': confirmLabel,
      'typeLabel': typeLabel,
      'extensions': extensions,
    });
    return path == null ? null : selector.XFile(path);
  }

  static Future<List<selector.XFile>> openFiles({
    required String typeLabel,
    required List<String> extensions,
  }) async {
    if (!_useNativeChannel) {
      return selector.openFiles(
        acceptedTypeGroups: [
          selector.XTypeGroup(label: typeLabel, extensions: extensions),
        ],
      );
    }
    final paths = await _invoke<List<dynamic>>('openFiles', {
      'typeLabel': typeLabel,
      'extensions': extensions,
    });
    return [
      if (paths != null)
        for (final path in paths) selector.XFile(path as String),
    ];
  }

  static Future<T?> _invoke<T>(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      return await _channel
          .invokeMethod<T>(method, arguments)
          .timeout(_windowsTimeout, onTimeout: () {
        appLog(
          'warn',
          'file_dialog',
          '选择窗口 90 秒未弹出,已放行界面(可能存在无响应的网络位置),可换本地路径重试',
        );
        return null;
      });
    } on TimeoutException {
      return null;
    }
  }

  static Future<Map<Object?, Object?>?> _invokeMap(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      return await _channel
          .invokeMethod<Map<Object?, Object?>>(method, arguments)
          .timeout(_windowsTimeout, onTimeout: () {
        appLog(
          'warn',
          'file_dialog',
          '选择窗口 90 秒未弹出,已放行界面(可能存在无响应的网络位置),可换本地路径重试',
        );
        return null;
      });
    } on TimeoutException {
      return null;
    }
  }
}
