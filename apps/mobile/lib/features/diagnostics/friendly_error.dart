import 'dart:io';
import 'package:flutter/services.dart';

class MobileDiagnosticException implements Exception {
  const MobileDiagnosticException(this.cause, this.operation);
  final Object cause;
  final String operation;
  @override
  String toString() => cause.toString();
}

class FriendlyMobileError {
  const FriendlyMobileError(this.message, {this.cancelled = false});
  final String? message;
  final bool cancelled;
}

FriendlyMobileError friendlyMobileError(
  Object error, {
  String operation = 'project',
}) {
  if (error is MobileDiagnosticException) {
    return friendlyMobileError(error.cause, operation: error.operation);
  }
  final code = error is PlatformException ? error.code.toUpperCase() : '';
  final detail = error is PlatformException && error.details is Map
      ? error.details as Map
      : const {};
  final raw = '$code ${error.toString()} ${detail['kind'] ?? ''}'.toLowerCase();
  final errno = error is FileSystemException
      ? error.osError?.errorCode
      : detail['errno'];
  if (code.endsWith('_CANCELLED') ||
      raw.contains('导出已取消') ||
      raw.contains('分析已取消')) {
    return const FriendlyMobileError(null, cancelled: true);
  }
  if (code == 'ALREADY_ACTIVE' || raw.contains('already_active')) {
    return const FriendlyMobileError(
      '系统文件选择窗口还在占用，请稍等几秒再试；如果一直这样，请完全退出 App 后重新打开。',
    );
  }
  if (raw.contains('上一次导出尚未结束')) {
    return const FriendlyMobileError('上一次导出尚未结束，请稍后重试。');
  }
  if (errno == 28 ||
      raw.contains('enospc') ||
      raw.contains('no space left') ||
      raw.contains('disk full')) {
    return const FriendlyMobileError('手机存储空间不足，请清理后重试。');
  }
  if (errno == 13 ||
      errno == 1 ||
      raw.contains('permission denied') ||
      raw.contains('eacces') ||
      raw.contains('eperm') ||
      raw.contains('securityexception')) {
    return const FriendlyMobileError('没有读取这个文件的权限，请重新选择。');
  }
  if (code == 'UPDATE_FILE_MISSING' ||
      (errno == 2 && operation.startsWith('update'))) {
    return const FriendlyMobileError('更新安装包找不到了，请重新下载。');
  }
  if (errno == 2 || raw.contains('enoent') || raw.contains('no such file')) {
    return FriendlyMobileError(
      operation.startsWith('video') || operation.startsWith('playback')
          ? '视频文件找不到了，请重新选择原视频。'
          : '文件找不到了，请重新选择。',
    );
  }
  if (error is SocketException ||
      operation.startsWith('update') && raw.contains('network')) {
    return const FriendlyMobileError('连不上更新服务器，请检查网络');
  }
  if (code == 'EXPORT_BUSY') {
    return const FriendlyMobileError('这个输出文件正在导出，请稍后重试。');
  }
  if (code == 'INVALID_ARGUMENT') {
    return const FriendlyMobileError('设置无效，请检查视频范围后重试。');
  }
  if (raw.contains('decoder') ||
      raw.contains('codec') ||
      raw.contains('muxer') ||
      raw.contains('unsupported') ||
      raw.contains('无法解码')) {
    final mime =
        detail['mime']?.toString() ??
        RegExp(r'(?:audio|video)/[a-zA-Z0-9._+-]+').firstMatch(raw)?.group(0);
    const formats = {
      'video/hevc': 'HEVC',
      'video/avc': 'H.264',
      'audio/apac': 'APAC',
      'audio/mp4a-latm': 'AAC',
    };
    final format = formats[mime];
    return FriendlyMobileError(
      format == null ? '这个视频的格式手机无法处理。' : '这个视频的格式（$format）手机无法处理。',
    );
  }
  return FriendlyMobileError(switch (operation.split('.').first) {
    'analysis' => '出错了：视频分析未完成，请重试。',
    'export' => '出错了：视频导出未完成，请重试。',
    'update' => '出错了：更新操作未完成，请重试。',
    _ => '出错了：操作未完成，请重试。',
  });
}
