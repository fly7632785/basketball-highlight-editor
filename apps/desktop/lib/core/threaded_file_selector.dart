import 'dart:async';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';

/// Windows 的 [FileSelectorPlatform] 实现:对话框跑在 runner 的专用 STA 线程
/// 上(`bhe/native_file_dialog` 通道),shell 卡死(比如半死的网络映射盘)时
/// 只有对话框线程在等,主窗口保持可操作。90 秒无结果时放行调用方,runner
/// 的看门狗会同时尝试用 IDCANCEL 关闭卡住的对话框,释放会话槽位;若对话框
/// 卡在创建之前无法关闭,该会话槽位会保留到应用重启,后续请求会得到
/// `dialog_already_open` 错误而不是无限叠加线程。
class ThreadedFileSelectorWindows extends FileSelectorPlatform {
  static const MethodChannel _channel = MethodChannel('bhe/native_file_dialog');

  /// 与 runner 的看门狗保持一致。
  static const _dialogTimeout = Duration(seconds: 90);

  XTypeGroup? _firstGroup(List<XTypeGroup>? groups) =>
      (groups == null || groups.isEmpty) ? null : groups.first;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final group = _firstGroup(acceptedTypeGroups);
    final path = await _invoke<String>('open', {
      'confirmLabel': confirmButtonText,
      'initialDirectory': initialDirectory,
      'typeLabel': group?.label,
      'extensions': group?.extensions ?? const [],
    });
    return path == null ? null : XFile(path);
  }

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final group = _firstGroup(acceptedTypeGroups);
    final paths = await _invoke<List<dynamic>>('openFiles', {
      'confirmLabel': confirmButtonText,
      'initialDirectory': initialDirectory,
      'typeLabel': group?.label,
      'extensions': group?.extensions ?? const [],
    });
    return [
      if (paths != null)
        for (final path in paths) XFile(path as String),
    ];
  }

  @override
  Future<String?> getSavePath({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? suggestedName,
    String? confirmButtonText,
  }) async {
    final group = _firstGroup(acceptedTypeGroups);
    return _invoke<String>('save', {
      'suggestedName': suggestedName,
      'initialDirectory': initialDirectory,
      'typeLabel': group?.label,
      'extensions': group?.extensions ?? const [],
    });
  }

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    return _invoke<String>('directory', {
      'initialDirectory': initialDirectory,
      'confirmLabel': confirmButtonText,
    });
  }

  Future<T?> _invoke<T>(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final watch = Stopwatch()..start();
    appLog('info', 'file_dialog', '打开选择窗口 method=$method');
    try {
      final result = await _channel
          .invokeMethod<T>(method, arguments)
          .timeout(_dialogTimeout, onTimeout: () {
        appLog(
          'warn',
          'file_dialog',
          '选择窗口 90 秒未返回,已放行界面(可能存在无响应的网络位置),'
          '正在尝试关闭卡住的对话框,可换本地路径重试',
        );
        return null;
      });
      appLog(
        'info',
        'file_dialog',
        '选择窗口结束 method=$method result=${result == null ? '取消/超时' : '有结果'}'
        ' 用时 ${watch.elapsedMilliseconds}ms',
      );
      return result;
    } on TimeoutException {
      appLog('warn', 'file_dialog', '选择窗口超时 method=$method');
      return null;
    } on PlatformException catch (error) {
      appLog('warn', 'file_dialog',
          '选择窗口失败 method=$method code=${error.code}');
      if (error.code == 'dialog_already_open') {
        throw Exception('上一个选择窗口还没有关闭,请先关闭它再重试');
      }
      rethrow;
    }
  }
}
