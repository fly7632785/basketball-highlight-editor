part of '../../mobile_ui.dart';

class _ExportAudioNotice extends StatelessWidget {
  const _ExportAudioNotice();
  @override
  Widget build(BuildContext context) =>
      _InlineNotice(message: context.bheText('导出成功，部分音轨无法保留'));
}
