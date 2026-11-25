import 'dart:io';
import 'package:flutter/services.dart';

class MobileDiagnosticException implements Exception {
  const MobileDiagnosticException(this.cause, this.operation);
  final Object cause;
  final String operation;
  @override
  String toString() => cause.toString();
}

const portraitSourceAlreadyVertical =
    'This video is already portrait. Follow-ball cropping is unnecessary.';

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
  if (code == 'PORTRAIT_SOURCE_ALREADY_VERTICAL') {
    return const FriendlyMobileError(portraitSourceAlreadyVertical);
  }
  if (code == 'ALREADY_ACTIVE' || raw.contains('already_active')) {
    return const FriendlyMobileError(
      '系统文件选择窗口还在占用，请稍等几秒再试；如果一直这样，请完全退出 App 后重新打开。',
    );
  }
  if (raw.contains('上一次导出尚未结束')) {
    return const FriendlyMobileError('上一次导出尚未结束，请稍后重试。');
  }
  if (operation == 'gallery.save' &&
      (code == 'PHOTO_PERMISSION_DENIED' ||
          errno == 13 ||
          errno == 1 ||
          raw.contains('permission denied') ||
          raw.contains('eacces') ||
          raw.contains('eperm') ||
          raw.contains('securityexception'))) {
    return const FriendlyMobileError('没有相册保存权限，请在系统设置中允许 BHE 添加照片。');
  }
  if (code == 'PROJECT_METADATA_TOO_LARGE') {
    return const FriendlyMobileError('项目数据太大，无法在手机上导入。');
  }
  if (code == 'PROJECT_METADATA_MISSING' ||
      operation == 'project.import' && raw.contains('缺少 project.json')) {
    return const FriendlyMobileError('项目包缺少 project.json');
  }
  if (code == 'PROJECT_READ_PERMISSION') {
    return const FriendlyMobileError('没有读取这个文件的权限，请重新选择。');
  }
  if (code == 'PROJECT_IMPORT_FAILED') {
    return const FriendlyMobileError('无法导入项目，请重新选择 .bhe 或 .json 文件。');
  }
  if (code == 'VIDEO_STORAGE_INSUFFICIENT') {
    final missing = detail['missingBytes'];
    if (missing is num && missing > 0) {
      final gb = (missing / (1024 * 1024 * 1024)).toStringAsFixed(1);
      return FriendlyMobileError('手机空间不足，还需要约 ${gb == '0.0' ? '0.1' : gb} GB。');
    }
    return const FriendlyMobileError('手机存储空间不足，请清理后重试。');
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
  if (raw.contains('杜比视界视频转码失败')) {
    return const FriendlyMobileError('杜比视界视频转码失败，无法导出画面。');
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
    'share' => '无法打开分享面板，请重试。',
    'gallery' => '无法保存到相册，请重试。',
    'update' => '出错了：更新操作未完成，请重试。',
    _ => '出错了：操作未完成，请重试。',
  });
}
