/// Builds a readable default name while preserving names chosen by the user.
String defaultProjectName({
  required String fileName,
  DateTime? createdAt,
  required String locale,
  List<String> existingNames = const [],
  DateTime? now,
}) {
  final stem = fileName.replaceAll(RegExp(r'\.[^.]*$'), '').trim();
  final unreadable =
      stem.isEmpty ||
      RegExp(r'^[0-9]+$').hasMatch(stem) ||
      RegExp(r'^[0-9a-fA-F]{16,}$').hasMatch(stem) ||
      RegExp(
        r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
        caseSensitive: false,
      ).hasMatch(stem) ||
      RegExp(
        r'^(image|img|video|截屏|屏幕截图)[_-]?\d+$',
        caseSensitive: false,
      ).hasMatch(stem);
  if (!unreadable) return stem;

  final zh = locale.toLowerCase().startsWith('zh');
  late final String base;
  if (createdAt == null) {
    var index = 1;
    while (existingNames.contains('${zh ? '项目' : 'Project'} $index')) {
      index++;
    }
    return '${zh ? '项目' : 'Project'} $index';
  }
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
  base = zh
      ? '比赛 · ${createdAt.year}年${createdAt.month}月${createdAt.day}日'
      : 'Game · ${months[createdAt.month - 1]} ${createdAt.day}, ${createdAt.year}';
  if (!existingNames.contains(base)) return base;
  var suffix = 2;
  while (existingNames.contains('$base ($suffix)')) {
    suffix++;
  }
  return '$base ($suffix)';
}

String safeFileName(String value) => value
    .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '-')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
