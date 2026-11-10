/// Builds a readable default name while preserving names chosen by the user.
String defaultProjectName({
  required String fileName,
  DateTime? createdAt,
  /// true 表示 createdAt 其实是“导入时间”的兜底值，不是拍摄时间（L232 ③）。
  bool createdAtIsFallback = false,
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
        r'^(image|img|video|截屏|屏幕截图)[^A-Za-z]*[\w-]*$',
        caseSensitive: false,
      ).hasMatch(stem);
  if (!unreadable) return stem;

  final zh = locale.toLowerCase().startsWith('zh');
  late final String base;
  // L232 ③：读不到拍摄时间时不再用「项目 N」，改用导入日期命名
  // （形式同样是 'Game · Nov 10, 2026'；createdAtIsFallback 标明该日期来自导入，
  //  不是拍摄时间，避免被误当成比赛日期）。
  final effectiveDate = createdAt ?? (now ?? DateTime.now());
  // 供调用方/测试区分的兜底标记；命名本身不因它改变。
  // 供调用方/测试区分：命名用的是拍摄时间还是导入日期兜底。
  final usedImportDate = createdAtIsFallback || createdAt == null;
  assert(usedImportDate ? createdAt == null || createdAtIsFallback : true);
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
      ? '比赛 · ${effectiveDate.year}年${effectiveDate.month}月${effectiveDate.day}日'
      : 'Game · ${months[effectiveDate.month - 1]} ${effectiveDate.day}, ${effectiveDate.year}';
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
