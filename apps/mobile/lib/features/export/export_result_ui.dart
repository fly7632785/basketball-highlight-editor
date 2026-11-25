part of '../../mobile_ui.dart';

class _ExportTaskPage extends StatelessWidget {
  const _ExportTaskPage({required this.state});
  final MobileAppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      if (state.exportResult case final result?) {
        if (ModalRoute.isCurrentOf(context) == true)
          state.exportResultSeen = true;
        return _ExportResultPage(
          key: ObjectKey(result),
          state: state,
          live: result,
        );
      }

      final request = state.exportRequest!;
      final portrait = request.framing == ExportFraming.portrait916;
      final progress = state.portraitProgress;
      return Scaffold(
        key: const ValueKey('export-progress'),
        appBar: AppBar(title: Text(context.bheText('导出中'))),
        body: SafeArea(
          child: _ExportLayout(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          portrait
                              ? context.bheText('正在导出竖屏视频')
                              : _exportModeLabel(
                                  _exportL10n(context),
                                  request.mode,
                                ),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(context.bheText(state.progressMessage)),
                        if (progress != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            context.bheText(
                              '第 ${progress.clipIndex} / ${progress.clipCount} 段',
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Center(
                          child: SizedBox.square(
                            dimension: 76,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Positioned.fill(
                                  child: CircularProgressIndicator(
                                    value: state.progress.clamp(0, 1),
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                                  ),
                                ),
                                Text(
                                  '${(state.progress * 100).clamp(0, 100).round()}%',
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (portrait)
                          _PortraitExportSteps(
                            progress: progress,
                            merging: request.mode != MobileOutputMode.clips,
                          ),
                      ],
                    ),
                  ),
                ),
                if (portrait)
                  _InlineNotice(message: context.bheText('手机可能发热。请保持本页打开。')),
              ],
            ),
            actions: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: state.exportCancelled
                    ? null
                    : () => unawaited(state.cancelExport()),
                child: Text(context.bheText('取消导出')),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ExportResultPage extends StatefulWidget {
  const _ExportResultPage({
    super.key,
    required this.state,
    this.live,
    this.history,
  }) : assert((live == null) != (history == null));

  final MobileAppState state;
  final MobileExportResult? live;
  final ExportHistoryEntry? history;

  @override
  State<_ExportResultPage> createState() => _ExportResultPageState();
}

class _ExportResultPageState extends State<_ExportResultPage> {
  MobileAppState get state => widget.state;
  late final List<_ResultFile> files;
  late final Future<List<String?>> resolved;
  final _unchecked = <int>{};
  bool _didSave = false;
  bool _didShare = false;

  @override
  void initState() {
    super.initState();
    final entry = widget.history;
    if (entry != null) {
      files = [
        for (final file in entry.files)
          _ResultFile(
            name: file.relativePath.split('/').last,
            label: entry.mode == 'labels' && !file.untagged ? file.name : null,
            untagged: file.untagged,
            historical: file,
          ),
      ];
      resolved = Future.wait(entry.files.map(state.exportHistoryFilePath));
    } else {
      final result = widget.live!;
      files = [
        for (final file in result.files)
          _ResultFile(
            name: File(file.path).uri.pathSegments.last,
            label: file.label,
            untagged:
                result.request.mode == MobileOutputMode.labels &&
                file.label == null,
          ),
      ];
      resolved = Future.value([for (final file in result.files) file.path]);
    }
  }

  bool _isSaved(int index, String? path) {
    final historical = files[index].historical;
    if (path != null && state.gallerySavedPaths.contains(path)) return true;
    if (historical == null) return false;
    return historical.savedToGallery ||
        state.project.exportHistory
            .where((entry) => entry.id == widget.history!.id)
            .expand((entry) => entry.files)
            .any(
              (file) =>
                  file.relativePath == historical.relativePath &&
                  file.savedToGallery,
            );
  }

  Future<void> _retryExport() async {
    final result = widget.live!;
    final request = result.request;
    final choice = await showModalBottomSheet<ExportFraming>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final l10n = _exportL10n(context);
        return _SheetFrame(
          title: l10n.mobileRetryExportCount(request.outputCount),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (files.isNotEmpty && state.exportHistoryWarning == null)
                Text(l10n.mobileExistingExportsKept(files.length)),
              if (state.exportHistoryWarning case final warning?)
                Text(context.bheText(warning)),
              const SizedBox(height: 16),
              if (request.framing == ExportFraming.portrait916)
                OutlinedButton(
                  onPressed: () =>
                      Navigator.pop(context, ExportFraming.original),
                  child: Text(context.bheText('改用原比例导出')),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(context, request.framing),
                child: Text(l10n.mobileExportAllAgain),
              ),
            ],
          ),
        );
      },
    );
    if (mounted && choice != null) {
      unawaited(state.runExportRequest(request.withFraming(choice)));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => FutureBuilder<List<String?>>(
      future: resolved,
      builder: (context, snapshot) => _buildResult(context, snapshot.data),
    ),
  );

  Widget _buildResult(BuildContext context, List<String?>? paths) {
    final l10n = _exportL10n(context);
    final live = widget.live;
    final history = widget.history;
    final planned = live?.request.outputCount ?? history!.plannedCount;
    final cancelled = live?.cancelled == true;
    final count = files.length;
    final partial = count > 0 && count < planned;
    final complete = count > 0 && !partial;
    final failure = live?.failure;
    final error = !cancelled && count == 0;
    final canRun = state.exportStartBlockReason == null;
    final selected = <String>[];
    final unsaved = <String>[];
    if (paths != null) {
      for (var index = 0; index < paths.length; index++) {
        final path = paths[index];
        if (path == null || _unchecked.contains(index)) continue;
        selected.add(path);
        if (!_isSaved(index, path)) unsaved.add(path);
      }
    }
    final (title, icon, color) = switch ((cancelled, partial, error)) {
      (true, _, _) => (
        l10n.mobileExportCancelled(count),
        LucideIcons.circleMinus,
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      (_, true, _) => (
        l10n.mobileExportPartial(count, planned - count),
        LucideIcons.circleAlert,
        BhePalette.gold,
      ),
      (_, _, true) => (
        l10n.mobileExportFailed,
        LucideIcons.circleX,
        Theme.of(context).colorScheme.error,
      ),
      _ => (
        live?.request.framing == ExportFraming.portrait916
            ? l10n.mobilePortraitReady(count)
            : live?.request.mode == MobileOutputMode.merged ||
                  history?.mode == 'merged'
            ? l10n.mobileHighlightsReady
            : l10n.mobileExportReady(count),
        LucideIcons.circleCheck,
        BhePalette.green,
      ),
    };
    final failedStep = live?.portraitProgress;
    final failedContext = switch (failedStep?.step) {
      PortraitExportStep.merge => l10n.mobileFailedMerge,
      PortraitExportStep.sample ||
      PortraitExportStep.plan ||
      PortraitExportStep.render =>
        failedStep?.eventMs == null
            ? l10n.mobileExportDidNotFinish
            : l10n.mobileExportClipFailed(
                failedStep!.clipIndex,
                _formatMs(failedStep.eventMs!),
              ),
      null => l10n.mobileExportDidNotFinish,
    };
    final showRetry = live != null && !complete;

    return Scaffold(
      key: const ValueKey('export-result'),
      appBar: AppBar(title: Text(context.bheText('导出结果'))),
      body: SafeArea(
        child: _ExportLayout(
          body: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                sliver: SliverList.list(
                  children: [
                    Semantics(
                      header: true,
                      liveRegion: true,
                      child: Row(
                        children: [
                          Icon(icon, size: 28, color: color),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (live?.request.framing == ExportFraming.portrait916 &&
                        count > 0)
                      const Text('1080 × 1920'),
                    if (history != null)
                      Text(_historyDate(context, history.createdAt)),
                    if (live?.audioSkipped == true && count > 0)
                      const _ExportAudioNotice(),
                    if (live?.mergedOverlapCount case final overlap?
                        when overlap > 0 && count > 0)
                      _ExportOverlapNotice(count: overlap),
                    if (live != null && live.noBallCount > 0 && count > 0)
                      _InlineNotice(
                        message: context.bheText(
                          '${live.noBallCount} 段没找到球，画面可能不准',
                        ),
                      ),
                    if (live != null && state.hasUncertainExport)
                      _UncertainExportNotice(state: state),
                    if (failure != null && !complete && !cancelled)
                      if (state.videoSourceFailure != null ||
                          state.relinkingVideo)
                        VideoSourceNotice(state: state)
                      else
                        _ExportFailureNotice(
                          title: failedContext,
                          failure: failure,
                        ),
                    if ((live != null || _didSave) &&
                        state.exportHistoryWarning != null)
                      _ExportFailureNotice(
                        failure: (
                          message: state.exportHistoryWarning!,
                          diagnostic: state.exportHistoryDiagnostic,
                        ),
                      ),
                    if (showRetry && files.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: canRun ? _retryExport : null,
                            child: Text(l10n.mobileExportAllAgain),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(l10n.mobileChangeExportSettings),
                          ),
                        ],
                      ),
                    if (count > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          paths == null || count == 1
                              ? l10n.mobileExportFileCount(count)
                              : l10n.mobileExportSelected(
                                  selected.length,
                                  count,
                                ),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                  ],
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                sliver: SliverList.builder(
                  itemCount: count,
                  itemBuilder: (context, index) {
                    final file = files[index];
                    final path = paths?[index];
                    final saved = _isSaved(index, path);
                    final status = paths == null
                        ? l10n.mobileExportCheckingFiles
                        : path == null
                        ? context.bheText(saved ? '已保存到相册，请在相册查看' : '本机文件不可用')
                        : saved
                        ? context.bheText('已保存到相册')
                        : null;
                    return Card(
                      child: CheckboxListTile(
                        key: ValueKey('export-file-$index'),
                        title: Text(
                          file.label != null || file.untagged
                              ? _exportLabel(context, file.label)
                              : file.name,
                        ),
                        subtitle:
                            file.label != null ||
                                file.untagged ||
                                status != null
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (file.label != null || file.untagged)
                                    Text(file.name),
                                  if (status != null) Text(status),
                                ],
                              )
                            : null,
                        value: path != null && !_unchecked.contains(index),
                        onChanged: path == null || state.savingToGallery
                            ? null
                            : (checked) => setState(() {
                                checked == true
                                    ? _unchecked.remove(index)
                                    : _unchecked.add(index);
                              }),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          actions: count == 0
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showRetry)
                      FilledButton(
                        onPressed: canRun ? _retryExport : null,
                        child: Text(l10n.mobileExportAllAgain),
                      ),
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.mobileChangeExportSettings),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_didSave && state.savingToGallery) ...[
                      Text(context.bheText(state.progressMessage)),
                      LinearProgressIndicator(
                        value: state.progress.clamp(0, 1),
                      ),
                    ],
                    if (state.gallerySaveFailure case final saveFailure?
                        when _didSave)
                      _ExportFailureNotice(
                        key: const ValueKey('export-save-error'),
                        title: l10n.mobileExportSaveError,
                        failure: saveFailure,
                      ),
                    if (state.shareFailure case final shareFailure?
                        when _didShare)
                      _ExportFailureNotice(
                        title: l10n.mobileExportShareError,
                        failure: shareFailure,
                      ),
                    if (paths != null && selected.isEmpty)
                      Text(l10n.mobileExportSelectFiles),
                    _ResultActions(
                      onShare: selected.isEmpty || state.sharingExports
                          ? null
                          : (origin) {
                              setState(() => _didShare = true);
                              return state.shareExportedFiles(
                                paths: selected,
                                origin: origin,
                              );
                            },
                      saveText: l10n.mobileSaveExportCount(unsaved.length),
                      onSave: unsaved.isEmpty || !canRun
                          ? null
                          : () {
                              setState(() => _didSave = true);
                              unawaited(
                                state.saveExportedFiles(paths: unsaved),
                              );
                            },
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _ResultFile {
  const _ResultFile({
    required this.name,
    this.label,
    this.untagged = false,
    this.historical,
  });
  final String name;
  final String? label;
  final bool untagged;
  final ExportHistoryFile? historical;
}

class _ResultActions extends StatelessWidget {
  const _ResultActions({
    required this.onShare,
    required this.onSave,
    required this.saveText,
  });
  final Future<void> Function(Rect)? onShare;
  final VoidCallback? onSave;
  final String saveText;

  @override
  Widget build(BuildContext context) {
    final share = Builder(
      builder: (context) => OutlinedButton(
        key: const ValueKey('export-share'),
        onPressed: onShare == null
            ? null
            : () {
                final button = context.findRenderObject()! as RenderBox;
                unawaited(
                  onShare!(button.localToGlobal(Offset.zero) & button.size),
                );
              },
        child: Text(context.bheText('分享'), textAlign: TextAlign.center),
      ),
    );
    final save = FilledButton(
      key: const ValueKey('export-save'),
      onPressed: onSave,
      child: Text(saveText, textAlign: TextAlign.center),
    );
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth < 290 &&
              MediaQuery.textScalerOf(context).scale(14) > 19
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [share, save],
            )
          : Row(
              children: [
                Expanded(child: share),
                const SizedBox(width: 8),
                Expanded(flex: 2, child: save),
              ],
            ),
    );
  }
}

class _ExportFailureNotice extends StatelessWidget {
  const _ExportFailureNotice({super.key, this.title, required this.failure});
  final String? title;
  final MobileExportFailure failure;

  @override
  Widget build(BuildContext context) => _InlineNotice(
    message: [
      if (title != null) title!,
      context.bheText(failure.message),
    ].join('\n'),
    error: true,
    action: TextButton(
      onPressed: () =>
          showMobileDiagnostics(context, error: failure.diagnostic),
      child: Text(context.bheText('反馈')),
    ),
  );
}
