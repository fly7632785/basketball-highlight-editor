part of '../../mobile_ui.dart';

String _exportLabel(BuildContext context, String? label) {
  if (label == null) return context.bheText('未标记');
  if (label == '未标记') return '$label（${context.bheText('标签')}）';
  return label;
}

class _ExportModeSelector extends StatelessWidget {
  const _ExportModeSelector({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });
  final MobileOutputMode mode;
  final bool enabled;
  final ValueChanged<MobileOutputMode> onChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.bheText('输出方式'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          for (final value in MobileOutputMode.values) ...[
            _ExportModeCard(
              mode: value,
              selected: value == mode,
              enabled: enabled,
              onTap: () => onChanged(value),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    ),
  );
}

class _ExportScopeSummary extends StatelessWidget {
  const _ExportScopeSummary({
    required this.selected,
    required this.scope,
    required this.omitted,
    required this.duration,
    required this.folded,
    required this.skippedUntagged,
    required this.mode,
    required this.framing,
    required this.onStart,
  });

  final List<Candidate> selected;
  final ExportScope scope;
  final Map<MobileTier, int> omitted;
  final int duration;
  final int folded;
  final int skippedUntagged;
  final MobileOutputMode mode;
  final ExportFraming framing;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final groups = mode == MobileOutputMode.labels
        ? labelExportGroups(selected, scope: scope)
        : const <LabelExportGroup>[];
    final videoCount = mode == MobileOutputMode.merged ? 1 : groups.length;
    final summary = selected.isEmpty
        ? context.bheText('没有可导出的片段')
        : [
            context.bheText(
              framing == ExportFraming.portrait916
                  ? '将导出 ${videoCount == 0 ? selected.length : videoCount} 个竖屏视频'
                  : videoCount == 0
                  ? '将导出 ${selected.length} 段'
                  : '将导出 $videoCount 个视频 · 共 ${selected.length} 段',
            ),
            _formatMs(duration),
          ].join(' · ');
    final details = [
      if (framing == ExportFraming.portrait916 && selected.isNotEmpty)
        context.bheText('需逐帧生成，比原比例慢且费电'),
      if (omitted.values.any((count) => count > 0))
        '${context.bheText('不导出')}  ${[for (final entry in omitted.entries)
          if (entry.value > 0) context.bheText('${entry.key.label} ${entry.value}')].join(' · ')}',
      if (folded > 0) context.bheText('其中很可能没进 $folded'),
      if (skippedUntagged > 0) context.bheText('没标签的 $skippedUntagged 段不导出'),
      if (groups.isNotEmpty)
        groups
            .map(
              (g) =>
                  '${_exportLabel(context, g.label)} (${g.candidates.length})',
            )
            .join(' · '),
    ];
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: selected.isEmpty ? null : BhePalette.orange,
                  ),
                ),
                if (details.isNotEmpty)
                  Text(
                    details.join(' · '),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: onStart,
              child: Text(context.bheText('开始导出')),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportModeCard extends StatelessWidget {
  const _ExportModeCard({
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });
  final MobileOutputMode mode;
  final bool selected, enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final (title, description) = switch (mode) {
      MobileOutputMode.clips => ('每个片段原样导出', '分别保存每个片段'),
      MobileOutputMode.merged => ('合并成一个视频', '按时间拼成一条集锦'),
      MobileOutputMode.labels => ('每个标签各合成一个视频', '只为选中的标签生成视频，不限时按全部标签分组'),
    };
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.bheText(title),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        context.bheText(description),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 导出结果里的明确操作用强调色，避免被主题的灰色文字按钮看成不可点。
final _exportActionStyle = TextButton.styleFrom(
  foregroundColor: BhePalette.orange,
);

class _LabelExportResultRow extends StatelessWidget {
  const _LabelExportResultRow({required this.state, required this.item});
  final MobileAppState state;
  final LabelExportFile item;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _exportLabel(context, item.label),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (item.label != File(item.path).uri.pathSegments.last)
          Text(
            File(item.path).uri.pathSegments.last,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              style: _exportActionStyle,
              onPressed: () =>
                  unawaited(state.shareExportedFiles(paths: [item.path])),
              child: Text(context.bheText('分享')),
            ),
            TextButton(
              style: _exportActionStyle,
              onPressed: state.exportStartBlockReason == null
                  ? () => unawaited(state.saveExportedFiles(paths: [item.path]))
                  : null,
              child: Text(context.bheText('保存到相册')),
            ),
          ],
        ),
      ],
    ),
  );
}
