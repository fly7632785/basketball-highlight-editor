part of '../../mobile_ui.dart';

class _ExportView extends StatefulWidget {
  const _ExportView({
    super.key,
    required this.state,
    required this.allowanceBuilder,
    required this.goalsOnly,
    required this.onBackToReview,
  });
  final MobileAppState state;
  final WidgetBuilder? allowanceBuilder;
  final bool goalsOnly;
  final VoidCallback onBackToReview;

  @override
  State<_ExportView> createState() => _ExportViewState();
}

class _ExportViewState extends State<_ExportView> {
  late ExportScope scope = ExportScope.anyTag(
    tiers: widget.goalsOnly
        ? const {MobileTier.goal}
        : defaultMobileExportTiers,
  );
  MobileOutputMode outputMode = MobileOutputMode.clips;
  ExportFraming _framing = ExportFraming.original;
  VideoInfo? _probedVideo;
  Future<bool?>? _hdrProbe;

  MobileAppState get state => widget.state;

  bool get _sourceAlreadyPortrait {
    final video = state.project.video;
    return video != null &&
        video.width > 0 &&
        video.height > 0 &&
        video.width * 16 <= video.height * 9;
  }

  ExportFraming get framing =>
      _sourceAlreadyPortrait ? ExportFraming.original : _framing;

  void _selectFraming(ExportFraming value) {
    final video = state.project.video;
    if (value == ExportFraming.portrait916 && !identical(video, _probedVideo)) {
      _probedVideo = video;
      _hdrProbe = video == null || video.isHdr != null
          ? null
          : readProjectVideoMetadata(video.path).then((data) => data.isHdr);
    }
    setState(() => _framing = value);
  }

  bool _openingTask = false;
  bool _reminding = false;

  Future<void> _startExport(MobileExportRequest request) async {
    if (_reminding) return;
    final untagged = _untaggedReminderCount(
      state,
      request.scope,
      request.mode,
      request.candidates,
    );
    if (untagged > 0) {
      _reminding = true;
      final choice = await _showUntaggedReminder(context, untagged);
      _reminding = false;
      if (!mounted) return;
      if (choice == _UntaggedChoice.backToReview) {
        widget.onBackToReview();
        return;
      }
      if (choice != _UntaggedChoice.exportAnyway) return;
    }
    unawaited(state.runExportRequest(request));
    if (state.exportInProgress) await _openTask();
  }

  Future<void> _openTask() async {
    if (_openingTask || !mounted || ModalRoute.isCurrentOf(context) != true) {
      return;
    }
    _openingTask = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => _ExportTaskPage(state: state)),
      );
    } finally {
      if (mounted) setState(() => _openingTask = false);
    }
  }

  Future<void> _chooseScope() async {
    final updated = await showModalBottomSheet<ExportScope>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ExportScopeSheet(
        project: state.project,
        initial: scope,
        mode: outputMode,
        likelyMissIds: state.likelyMissCandidateIds,
      ),
    );
    if (mounted && updated != null) setState(() => scope = updated);
  }

  Future<void> _chooseOutputMode() async {
    var selected = outputMode;
    final updated = await showModalBottomSheet<MobileOutputMode>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, change) => _SheetFrame(
          title: context.bheText('输出方式'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final mode in MobileOutputMode.values)
                _ChoiceRow(
                  title: _exportModeLabel(_exportL10n(context), mode),
                  subtitle: context.bheText(switch (mode) {
                    MobileOutputMode.clips => '分别保存每个片段',
                    MobileOutputMode.merged => '按时间拼成一条集锦',
                    MobileOutputMode.labels => '只为选中的标签生成视频，不限时按全部标签分组',
                  }),
                  selected: selected == mode,
                  onTap: () => change(() => selected = mode),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(context, selected),
                child: Text(context.bheText('完成')),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && updated != null) setState(() => outputMode = updated);
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == true &&
        state.exportResult != null &&
        !state.exportResultSeen &&
        !_openingTask) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (state.exportResult != null && !state.exportResultSeen) {
          unawaited(_openTask());
        }
      });
    }

    final l10n = _exportL10n(context);
    final candidates = state.project.candidates;
    final selected = scope.select(candidates, outputMode);
    final tagSummary = scope.active
        ? [
            for (final player in scope.players) _exportLabel(context, player),
            if (scope.includeUntagged) _exportLabel(context, null),
          ].join(' · ')
        : l10n.mobileAllTags;
    final blocked = state.exportStartBlockReason != null;
    final running = state.exportInProgress;
    final duration = selected.fold<int>(
      0,
      (sum, clip) => sum + clip.duration.inMilliseconds,
    );
    final outputCount = switch (outputMode) {
      MobileOutputMode.clips => selected.length,
      MobileOutputMode.merged => selected.isEmpty ? 0 : 1,
      MobileOutputMode.labels => labelExportGroups(
        selected,
        scope: scope,
      ).length,
    };
    final plan = framing == ExportFraming.portrait916
        ? context.bheText('将导出 $outputCount 个竖屏视频')
        : outputMode == MobileOutputMode.clips
        ? l10n.mobileExportClipPlan(selected.length)
        : context.bheText('将导出 $outputCount 个视频 · 共 ${selected.length} 段');
    return _ExportLayout(
      body: ListView(
        key: const ValueKey('export-settings'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          if (state.hasUncertainExport)
            _UncertainExportNotice(state: state, forExport: true),
          if (state.hasUncertainAnalysis) ...[
            _UncertainAnalysisNotice(state: state),
            const _InlineNotice(message: '上次分析尚未确认停止，暂时不能导出。'),
          ],
          if (state.exportStartBlockReason case final reason?
              when !running &&
                  !state.hasUncertainExport &&
                  !state.hasUncertainAnalysis)
            _InlineNotice(message: reason),
          if (state.videoSourceFailure != null || state.relinkingVideo)
            VideoSourceNotice(state: state),
          _ExportSettingsRow(
            key: const ValueKey('export-scope'),
            icon: LucideIcons.listFilter,
            title: l10n.mobileWhatToExport,
            subtitle: [
              for (final tier in MobileTier.values)
                if (scope.tiers.contains(tier)) context.bheText(tier.label),
              tagSummary,
            ].join(' · '),
            onTap: blocked ? null : _chooseScope,
          ),
          _ExportSettingsRow(
            key: const ValueKey('export-mode'),
            icon: LucideIcons.layers,
            title: context.bheText('输出方式'),
            subtitle: _exportModeLabel(l10n, outputMode),
            onTap: blocked ? null : _chooseOutputMode,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.bheText('画面'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Flexible(
                flex: 2,
                child: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (context) => _ExportFramingGuide(
                      isHdr: state.project.video?.isHdr,
                      hdrProbe: identical(state.project.video, _probedVideo)
                          ? _hdrProbe
                          : null,
                    ),
                  ),
                  child: Text(l10n.mobileCropGuide, textAlign: TextAlign.end),
                ),
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, limits) {
              final tiles = [
                for (final value in ExportFraming.values)
                  Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: framing == value
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ExcludeSemantics(
                          child: ClipRect(
                            child: CustomPaint(
                              size: const Size(0, 44),
                              painter: _PortraitFramingDiagram(
                                cropped: value == ExportFraming.portrait916,
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: _ChoiceRow(
                            title: context.bheText(_framingLabel(value)),
                            subtitle: switch (value) {
                              ExportFraming.original => context.bheText(
                                '不裁切，比竖屏快',
                              ),
                              ExportFraming.portrait916
                                  when _sourceAlreadyPortrait =>
                                _sourceAlreadyPortraitHint(context),
                              ExportFraming.portrait916 => context.bheText(
                                '需逐帧生成，比原比例慢且费电',
                              ),
                            },
                            selected: framing == value,
                            onTap:
                                blocked ||
                                    (value == ExportFraming.portrait916 &&
                                        _sourceAlreadyPortrait)
                                ? null
                                : () => _selectFraming(value),
                          ),
                        ),
                      ],
                    ),
                  ),
              ];
              return limits.maxWidth >= 325 &&
                      MediaQuery.textScalerOf(context).scale(14) < 21
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: tiles.first),
                        const SizedBox(width: 8),
                        Expanded(child: tiles.last),
                      ],
                    )
                  : Column(
                      children: [
                        tiles.first,
                        const SizedBox(height: 8),
                        tiles.last,
                      ],
                    );
            },
          ),
          if (framing == ExportFraming.portrait916)
            _PortraitHdrHint(
              isHdr: state.project.video?.isHdr,
              probe: identical(state.project.video, _probedVideo)
                  ? _hdrProbe
                  : null,
            ),
          const SizedBox(height: 12),
          _ExportSettingsRow(
            key: const ValueKey('export-history'),
            icon: LucideIcons.history,
            title: context.bheText('导出历史'),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => _ExportHistoryPage(state: state),
              ),
            ),
          ),
          if (candidates.isNotEmpty)
            _ExportSettingsRow(
              key: const ValueKey('export-stats'),
              icon: Icons.bar_chart_rounded,
              title: context.bheText('比赛数据'),
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => _ExportStatsPage(state: state),
                ),
              ),
            ),
        ],
      ),
      actions: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.allowanceBuilder case final builder?) ...[
            Builder(builder: builder),
            const SizedBox(height: 8),
          ],
          Text(
            running
                ? '${context.bheText('导出中')} · ${(state.progress * 100).clamp(0, 100).round()}%'
                : selected.isEmpty
                ? context.bheText('没有可导出的片段')
                : '$plan · ${l10n.mobileClipsTotal(_formatMs(duration))}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: running
                ? _openTask
                : blocked || outputCount == 0
                ? null
                : () => unawaited(
                    _startExport(
                      MobileExportRequest(
                        scope: scope,
                        mode: outputMode,
                        framing: framing,
                        candidates: selected,
                      ),
                    ),
                  ),
            child: Text(
              running ? l10n.mobileViewProgress : context.bheText('开始导出'),
            ),
          ),
        ],
      ),
    );
  }
}

BheLocalizations _exportL10n(BuildContext context) =>
    BheLocalizations.of(context);

String _exportModeLabel(BheLocalizations l10n, MobileOutputMode mode) =>
    switch (mode) {
      MobileOutputMode.clips => l10n.mobileOnePerClip,
      MobileOutputMode.merged => l10n.mobileOneMerged,
      MobileOutputMode.labels => l10n.mobileOnePerTag,
    };

class _ExportLayout extends StatelessWidget {
  const _ExportLayout({required this.body, this.actions});
  final Widget body;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 950),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (actions == null) return body;
          final panel = Material(
            color: Theme.of(context).brightness == Brightness.dark
                ? BhePalette.surface
                : Theme.of(context).colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: actions,
            ),
          );
          if (constraints.maxWidth >= 650 && constraints.maxHeight < 500) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: body),
                SizedBox(
                  width: (constraints.maxWidth * .35)
                      .clamp(250, 325)
                      .toDouble(),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Flexible(child: SingleChildScrollView(child: panel)),
                    ],
                  ),
                ),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: body),
              panel,
            ],
          );
        },
      ),
    ),
  );
}

class _ExportSettingsRow extends StatelessWidget {
  const _ExportSettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(icon, size: 20),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(LucideIcons.chevronRight, size: 18),
      enabled: onTap != null,
      onTap: onTap,
    ),
  );
}

class _ExportScopeSheet extends StatefulWidget {
  const _ExportScopeSheet({
    required this.project,
    required this.initial,
    required this.mode,
    required this.likelyMissIds,
  });
  final ProjectSnapshot project;
  final ExportScope initial;
  final MobileOutputMode mode;
  final Set<String> likelyMissIds;

  @override
  State<_ExportScopeSheet> createState() => _ExportScopeSheetState();
}

class _ExportScopeSheetState extends State<_ExportScopeSheet> {
  late ExportScope scope = widget.initial;

  @override
  Widget build(BuildContext context) {
    final l10n = _exportL10n(context);
    final candidates = widget.project.candidates;
    final counts = {for (final tier in MobileTier.values) tier: 0};
    final labelCounts = {for (final label in widget.project.players) label: 0};
    var inTiers = 0;
    var untagged = 0;
    for (final clip in candidates) {
      final tier = mobileTier(clip);
      counts[tier] = counts[tier]! + 1;
      if (!scope.tiers.contains(tier)) continue;
      inTiers++;
      final labels = exportLabels(clip);
      if (labels.isEmpty) untagged++;
      for (final label in labels) {
        labelCounts.update(label, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    final perTag = widget.mode == MobileOutputMode.labels;
    final selected = scope.select(candidates, widget.mode);
    final selectedIds = selected.map((clip) => clip.id).toSet();
    final omitted = {for (final tier in MobileTier.values) tier: 0};
    for (final clip in candidates) {
      if (!selectedIds.contains(clip.id)) {
        final tier = mobileTier(clip);
        omitted[tier] = omitted[tier]! + 1;
      }
    }
    final folded = selected
        .where((clip) => isFoldedCandidate(clip, widget.likelyMissIds))
        .length;
    final details = [
      if (omitted.values.any((count) => count > 0))
        '${context.bheText('不导出')}  ${[for (final entry in omitted.entries)
          if (entry.value > 0) context.bheText('${entry.key.label} ${entry.value}')].join(' · ')}',
      if (folded > 0) context.bheText('其中很可能没进 $folded'),
      if (perTag && untagged > 0) context.bheText('没标签的 $untagged 段不导出'),
    ];
    return _SheetFrame(
      title: l10n.mobileWhatToExport,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.bheText('档位')),
          Wrap(
            spacing: 8,
            children: [
              for (final tier in MobileTier.values)
                FilterChip(
                  key: ValueKey('export-tier-${tier.name}'),
                  label: Text('${context.bheText(tier.label)} ${counts[tier]}'),
                  selected: scope.tiers.contains(tier),
                  onSelected: (on) => setState(() {
                    final next = {...scope.tiers};
                    on ? next.add(tier) : next.remove(tier);
                    scope = scope.withTiers(next);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(context.bheText('标签')),
          Wrap(
            spacing: 8,
            children: [
              _ScopeChoiceChip(
                label: l10n.mobileAllTags,
                count: perTag ? inTiers - untagged : inTiers,
                selected: !scope.active,
                onSelected: (_) => setState(
                  () => scope = ExportScope.anyTag(tiers: scope.tiers),
                ),
              ),
              for (final entry in labelCounts.entries)
                _PlayerChoiceChip(
                  player: entry.key,
                  count: entry.value,
                  selected: scope.active && scope.players.contains(entry.key),
                  onSelected: (on) => setState(() {
                    final labels = {...scope.players};
                    on ? labels.add(entry.key) : labels.remove(entry.key);
                    scope = ExportScope.only(
                      labels,
                      includeUntagged: scope.active && scope.includeUntagged,
                      tiers: scope.tiers,
                    ).normalized;
                  }),
                ),
              if (!perTag &&
                  (untagged > 0 || scope.active && scope.includeUntagged))
                _ScopeChoiceChip(
                  label: context.bheText('未标记'),
                  count: untagged,
                  selected: scope.active && scope.includeUntagged,
                  onSelected: (on) => setState(() {
                    scope = ExportScope.only(
                      scope.players,
                      includeUntagged: on,
                      tiers: scope.tiers,
                    ).normalized;
                  }),
                ),
            ],
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              details.join('\n'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.pop(context, scope),
            child: Text(context.bheText('完成')),
          ),
        ],
      ),
    );
  }
}

class _ExportStatsPage extends StatelessWidget {
  const _ExportStatsPage({required this.state});
  final MobileAppState state;

  @override
  Widget build(BuildContext context) {
    final project = state.project;
    return Scaffold(
      appBar: AppBar(title: Text(context.bheText('比赛数据'))),
      body: SafeArea(
        child: _ExportLayout(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _GameStatsBody(
                stats: computeGameStats(
                  project.candidates,
                  project.players,
                  videoDurationMs: project.video?.durationMs ?? 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
