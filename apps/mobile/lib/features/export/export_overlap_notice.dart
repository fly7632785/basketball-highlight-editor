part of '../../mobile_ui.dart';

class _ExportOverlapNotice extends StatelessWidget {
  const _ExportOverlapNotice({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) =>
      _InlineNotice(message: context.bheText('合并后减少了 $count 个片段'));
}
