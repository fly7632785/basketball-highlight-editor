import 'dart:io';

import 'package:flutter/services.dart';

const projectMediaChannel = MethodChannel('com.bhe.bhe/mobile_media');

Future<({DateTime? capturedAt, double? frameRate, String? codec, bool? isHdr})>
readProjectVideoMetadata(String path, {bool useModifiedTime = false}) async {
  Map<String, dynamic>? metadata;
  try {
    metadata = await projectMediaChannel.invokeMapMethod<String, dynamic>(
      'videoMetadata',
      {'path': path},
    );
  } on MissingPluginException {
    // Host tests and older platforms may not have the metadata bridge.
  } on PlatformException {
    // The optional metadata does not prevent import.
  }
  final raw = metadata?['creationTime'] as String?;
  final captured = DateTime.tryParse(raw ?? '');
  final stat =
      useModifiedTime && captured == null && !path.startsWith('content://')
      ? await File(path).stat()
      : null;
  final modified = (metadata?['modifiedMs'] as num?)?.toInt();
  final rate = (metadata?['frameRate'] as num?)?.toDouble();
  return (
    capturedAt:
        captured ??
        (modified == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(modified)) ??
        (stat?.type == FileSystemEntityType.file ? stat?.modified : null),
    frameRate: rate != null && rate.isFinite && rate > 0 ? rate : null,
    codec: metadata?['codec'] as String?,
    isHdr: metadata?['isHdr'] as bool?,
  );
}

String projectRecordingTitle(DateTime date, int durationMs, String locale) {
  final t = date.toLocal();
  final minute = t.minute.toString().padLeft(2, '0');
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final mins = durationMs ~/ 60000;
  final seconds = (durationMs ~/ 1000).clamp(1, 59);
  if (locale.startsWith('en')) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[t.month - 1]} ${t.day}, $hour:$minute ${t.hour < 12 ? 'AM' : 'PM'} · ${mins > 0 ? '$mins min' : '$seconds sec'}';
  }
  return '${t.month}月${t.day}日 ${t.hour < 12 ? '上午' : '下午'}$hour:$minute · ${mins > 0 ? '$mins分钟' : '$seconds秒'}';
}
