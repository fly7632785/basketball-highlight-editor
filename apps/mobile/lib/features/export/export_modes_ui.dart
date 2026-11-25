part of '../../mobile_ui.dart';

String _exportLabel(BuildContext context, String? label) {
  if (label == null) return context.bheText('未标记');
  if (label == '未标记') return '$label（${context.bheText('标签')}）';
  return label;
}
