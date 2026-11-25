part of '../../mobile_ui.dart';

String _framingLabel(ExportFraming value) => switch (value) {
  ExportFraming.original => '原比例',
  ExportFraming.portrait916 => '竖屏 9:16（跟球）',
};

String _sourceAlreadyPortraitHint(BuildContext context) => context.bheText(
  Localizations.localeOf(context).languageCode == 'zh'
      ? '这个视频本来就是竖屏，不需要跟球'
      : portraitSourceAlreadyVertical,
);

class _ExportFramingGuide extends StatelessWidget {
  const _ExportFramingGuide({required this.isHdr, required this.hdrProbe});

  final bool? isHdr;
  final Future<bool?>? hdrProbe;

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: _exportL10n(context).mobileCropGuide,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: const CustomPaint(
            size: Size(double.infinity, 112),
            painter: _PortraitFramingDiagram(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          context.bheText('橙框内为保留画面，框外会裁掉。输出 1080 × 1920。'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        _InlineNotice(
          message: context.bheText(
            '逐帧重新生成，慢且费电。建议插电并保持本页打开。1080p 原片裁切放大后会变糊一些。',
          ),
        ),
        _PortraitHdrHint(isHdr: isHdr, probe: hdrProbe),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.bheText('完成')),
        ),
      ],
    ),
  );
}

class _PortraitFramingDiagram extends CustomPainter {
  const _PortraitFramingDiagram({this.cropped = true});
  final bool cropped;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF12272D);
    canvas.drawRect(Offset.zero & size, paint);
    final floor = size.height * .62;
    paint.color = const Color(0xFF285F4E);
    canvas.drawRect(
      Rect.fromLTWH(0, floor, size.width, size.height - floor),
      paint,
    );
    paint.color = const Color(0xFF7DAB9C);
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 1;
    final court = Path()
      ..moveTo(0, size.height * .87)
      ..quadraticBezierTo(size.width / 2, floor, size.width, size.height * .87);
    canvas.drawPath(court, paint);
    final rim = Offset(size.width * .62, size.height * .39);
    paint.color = const Color(0xFFBECED3);
    canvas.drawRect(Rect.fromLTWH(rim.dx, rim.dy - 18, 31, 21), paint);
    canvas.drawLine(rim.translate(25, 3), rim.translate(25, 54), paint);
    canvas.drawLine(rim.translate(7, 5), rim.translate(22, 5), paint);
    paint.style = PaintingStyle.fill;
    paint.color = BhePalette.orange;
    canvas.drawCircle(rim.translate(-10, 0), 5, paint);
    if (!cropped) return;
    final crop = Rect.fromCenter(
      center: Offset(size.width * .61, size.height / 2),
      width: size.height * 9 / 16,
      height: size.height,
    );
    paint.color = const Color(0x88000000);
    canvas.drawRect(Rect.fromLTRB(0, 0, crop.left, size.height), paint);
    canvas.drawRect(
      Rect.fromLTRB(crop.right, 0, size.width, size.height),
      paint,
    );
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = BhePalette.orange;
    canvas.drawRect(crop.deflate(1), paint);
  }

  @override
  bool shouldRepaint(_PortraitFramingDiagram oldDelegate) =>
      cropped != oldDelegate.cropped;
}

class _PortraitHdrHint extends StatelessWidget {
  const _PortraitHdrHint({required this.isHdr, required this.probe});
  final bool? isHdr;
  final Future<bool?>? probe;

  @override
  Widget build(BuildContext context) => FutureBuilder<bool?>(
    future: probe,
    initialData: isHdr,
    builder: (context, snapshot) => snapshot.data == true
        ? Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _InlineNotice(
              message: context.bheText('将转为普通画质导出，颜色会比原片略平'),
            ),
          )
        : const SizedBox.shrink(),
  );
}

class _PortraitExportSteps extends StatelessWidget {
  const _PortraitExportSteps({required this.progress, required this.merging});
  final PortraitExportProgress? progress;
  final bool merging;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final (step, label) in [
        (PortraitExportStep.sample, context.bheText('找球和篮筐')),
        (
          PortraitExportStep.plan,
          Localizations.localeOf(context).languageCode == 'zh'
              ? '规划取景'
              : 'Plan framing',
        ),
        (PortraitExportStep.render, context.bheText('裁切并生成画面')),
        if (merging) (PortraitExportStep.merge, context.bheText('合并成一个视频')),
      ])
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            progress != null && progress!.step.index > step.index
                ? LucideIcons.check
                : progress?.step == step
                ? LucideIcons.play
                : LucideIcons.circle,
            size: 17,
          ),
          title: Text(label),
          selected: progress?.step == step,
        ),
    ],
  );
}
