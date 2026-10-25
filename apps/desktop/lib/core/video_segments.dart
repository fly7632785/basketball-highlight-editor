import 'engine_session.dart';

/// 按录制时间排序，没有录制时间的排在后面，同时间按文件名。
int compareByRecordingTime(JsonMap a, JsonMap b) {
  final left = DateTime.tryParse(a['recorded_at']?.toString() ?? '');
  final right = DateTime.tryParse(b['recorded_at']?.toString() ?? '');
  if (left != null && right != null && left != right) {
    return left.compareTo(right);
  }
  if ((left == null) != (right == null)) return left == null ? 1 : -1;
  return _fileName(a).compareTo(_fileName(b));
}

String _fileName(JsonMap video) =>
    (video['source_path']?.toString() ?? '').split(RegExp(r'[/\\]')).last;

/// 下一段紧接着上一段录制（相机按文件大小自动分段），机位没动，可以沿用篮筐。
bool continuesRecording(JsonMap previous, JsonMap next) {
  final start = DateTime.tryParse(previous['recorded_at']?.toString() ?? '');
  final nextStart = DateTime.tryParse(next['recorded_at']?.toString() ?? '');
  final duration = (previous['duration_ms'] as num?)?.toInt();
  if (start == null || nextStart == null || duration == null) return false;
  final gap = nextStart.difference(start.add(Duration(milliseconds: duration)));
  return gap.abs() <= const Duration(seconds: 10) &&
      previous['width'] == next['width'] &&
      previous['height'] == next['height'];
}

/// 视频段的篮筐还没设置，或只是可信度不够的自动识别结果，需要用户确认。
bool needsHoopConfirmation(JsonMap video) {
  final roi = video['roi'];
  if (roi is! Map) return true;
  return (roi['calibration'] as Map?)?['source'] == 'suggested';
}

/// 自动识别结果足够稳定时直接采用，否则让用户确认。
bool reliableRoiSuggestion(JsonMap calibration) {
  final confidence = (calibration['confidence'] as num?)?.toDouble() ?? 0;
  final stability = (calibration['stability'] as num?)?.toDouble() ?? 0;
  return confidence >= 0.5 && stability >= 0.5;
}
