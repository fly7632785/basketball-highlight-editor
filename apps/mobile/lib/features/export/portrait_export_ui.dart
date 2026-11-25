part of '../../mobile_ui.dart';

String _framingLabel(ExportFraming value) => switch (value) {
  ExportFraming.original => '原比例',
  ExportFraming.portrait916 => '竖屏 9:16（跟球）',
};

class _ExportFramingSheet extends StatefulWidget {
  const _ExportFramingSheet({
    required this.initial,
    required this.isHdr,
    required this.hdrProbe,
  });

  final ExportFraming initial;
  final bool? isHdr;
  final Future<bool?>? hdrProbe;

  @override
  State<_ExportFramingSheet> createState() => _ExportFramingSheetState();
}

class _ExportFramingSheetState extends State<_ExportFramingSheet> {
  late ExportFraming choice = widget.initial;

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: context.bheText('画面'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final value in ExportFraming.values)
          _ChoiceRow(
            title: context.bheText(_framingLabel(value)),
            subtitle: context.bheText(
              value == ExportFraming.original ? '不裁切，比竖屏快' : '从横屏里裁出竖条，镜头跟着球走',
            ),
            selected: choice == value,
            onTap: () => setState(() => choice = value),
          ),
        if (choice == ExportFraming.portrait916) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
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
          _PortraitHdrHint(isHdr: widget.isHdr, probe: widget.hdrProbe),
        ],
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => Navigator.pop(context, choice),
          child: Text(context.bheText('完成')),
        ),
      ],
    ),
  );
}

class _PortraitFramingDiagram extends CustomPainter {
  const _PortraitFramingDiagram();

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
  bool shouldRepaint(_PortraitFramingDiagram oldDelegate) => false;
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

class _PortraitExportRunning extends StatelessWidget {
  const _PortraitExportRunning({required this.state, required this.merging});

  final MobileAppState state;
  final bool merging;

  @override
  Widget build(BuildContext context) {
    final progress = state.portraitProgress;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              context.bheText('导出中'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.bheText('正在导出竖屏视频'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.bheText(
                        progress == null
                            ? state.progressMessage
                            : '第 ${progress.clipIndex} / ${progress.clipCount} 段',
                      ),
                    ),
                    if (progress != null &&
                        state.exportBatchTotal > 0 &&
                        !state.exportCancelled)
                      Text(context.bheText(state.progressMessage)),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: state.progress.clamp(0, 1)),
                    const SizedBox(height: 10),
                    for (final (step, label) in [
                      (PortraitExportStep.sample, '找球和篮筐'),
                      (PortraitExportStep.render, '裁切并生成画面'),
                      if (merging) (PortraitExportStep.merge, '合并成一个视频'),
                    ])
                      ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          progress != null && progress.step.index > step.index
                              ? LucideIcons.check
                              : progress?.step == step
                              ? LucideIcons.play
                              : LucideIcons.circle,
                          size: 17,
                        ),
                        title: Text(context.bheText(label)),
                        selected: progress?.step == step,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            _InlineNotice(message: context.bheText('手机可能发热。请保持本页打开。')),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: state.exportCancelled
                  ? null
                  : () => unawaited(state.cancelExport()),
              child: Text(context.bheText('取消导出')),
            ),
          ],
        ),
      ),
    );
  }
}

class _PortraitExportFailure extends StatelessWidget {
  const _PortraitExportFailure({
    required this.state,
    required this.onRetry,
    required this.onOriginal,
  });

  final MobileAppState state;
  final VoidCallback? onRetry, onOriginal;

  @override
  Widget build(BuildContext context) {
    final progress = state.portraitProgress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.bheText(switch (progress?.step) {
                    PortraitExportStep.merge => '合并没成功，已停下',
                    PortraitExportStep.sample || PortraitExportStep.render =>
                      '第 ${progress!.clipIndex} 段没导出成功，已停下',
                    null => '竖屏导出没成功，已停下',
                  }),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (progress?.eventMs case final event?) ...[
                  const SizedBox(height: 4),
                  Text('#${progress!.clipIndex} · ${_formatMs(event)}'),
                ],
                const SizedBox(height: 6),
                Text(context.bheText(state.portraitExportError!)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton(onPressed: onRetry, child: Text(context.bheText('重新导出'))),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: onOriginal,
          child: Text(context.bheText('改用原比例导出')),
        ),
      ],
    );
  }
}
