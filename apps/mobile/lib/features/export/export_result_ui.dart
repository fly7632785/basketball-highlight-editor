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
      final l10n = _exportL10n(context);
      final waiting = state.progressMessage == '正在结束上一次导出';
      final preparing = state.progressMessage == '正在检查视频';
      final cancelling = state.exportCancelled;
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
                        Text(
                          cancelling
                              ? l10n.mobileExportCancelling
                              : waiting
                              ? l10n.mobileExportWaiting
                              : context.bheText(state.progressMessage),
                        ),
                        if (progress != null) ...[
                          const SizedBox(height: 8),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              context.bheText(
                                '第 ${progress.clipIndex} / ${progress.clipCount} 段',
                              ),
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
                                    value: waiting || preparing || cancelling
                                        ? null
                                        : state.progress.clamp(0, 1),
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                                  ),
                                ),
                                if (!waiting && !preparing && !cancelling)
                                  Text(
                                    '${(state.progress * 100).clamp(0, 100).round()}%',
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (portrait && !waiting)
                          _PortraitExportSteps(
                            progress: progress,
                            merging: request.mode != MobileOutputMode.clips,
                          ),
                      ],
                    ),
                  ),
                ),
                _InlineNotice(message: l10n.mobileExportKeepOpen),
              ],
            ),
            actions: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: state.exportCancelled
                    ? null
                    : () => unawaited(state.cancelExport()),
                child: Text(
                  waiting
                      ? l10n.mobileExportStopWaiting
                      : context.bheText('取消导出'),
                ),
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
  final _noLongerAvailable = <int>{};
  final _shareFocus = FocusNode();
  bool _didSave = false;
  bool _didShare = false;
  bool _checkingSelection = false;
  List<int> _newlyMissing = const [];
  late bool _showFiles;

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
            localPath: file.path,
          ),
      ];
    }
    _showFiles = files.length <= 3;
    resolved = Future.wait(files.map(_availablePath));
  }

  @override
  void dispose() {
    _shareFocus.dispose();
    super.dispose();
  }

  Future<String?> _availablePath(_ResultFile file) async {
    if (file.historical case final historical?)
      return state.exportHistoryFilePath(historical);
    final local = file.localPath!;
    return await File(local).exists() ? local : null;
  }

  Future<List<String>> _verifySelection(List<int> indices) async {
    setState(() {
      _checkingSelection = true;
      _newlyMissing = const [];
    });
    final paths = await Future.wait(
      indices.map((index) => _availablePath(files[index])),
    );
    if (!mounted) return const [];
    final missing = [
      for (var index = 0; index < indices.length; index++)
        if (paths[index] == null) indices[index],
    ];
    setState(() {
      _checkingSelection = false;
      _newlyMissing = missing;
      _noLongerAvailable.addAll(missing);
      if (missing.isNotEmpty) _showFiles = true;
    });
    // Let the user see the changed selection before another system action.
    return missing.isEmpty ? paths.cast<String>() : const [];
  }

  Future<void> _save(List<int> indices) async {
    final paths = await _verifySelection(indices);
    if (!mounted || paths.isEmpty) return;
    setState(() => _didSave = true);
    await state.saveExportedFiles(paths: paths);
  }

  Future<void> _share(List<int> indices, Rect origin) async {
    final paths = await _verifySelection(indices);
    if (!mounted || paths.isEmpty) return;
    setState(() => _didShare = true);
    await state.shareExportedFiles(paths: paths, origin: origin);
    if (mounted && ModalRoute.isCurrentOf(context) == true) {
      _shareFocus.requestFocus();
    }
  }

  bool _isSaved(int index, String? path) {
    final historical = files[index].historical;
    if (state.gallerySavedPaths.contains(path ?? files[index].localPath))
      return true;
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
    final saveFailure = _didSave ? state.gallerySaveFailure : null;
    final shareFailure = _didShare ? state.shareFailure : null;
    final uncertain = live != null && state.hasUncertainExport;
    final error = !cancelled && count == 0;
    final canRun = state.exportStartBlockReason == null;
    final available = [
      if (paths != null)
        for (var index = 0; index < paths.length; index++)
          if (paths[index] != null && !_noLongerAvailable.contains(index))
            index,
    ];
    final selected = available
        .where((index) => !_unchecked.contains(index))
        .toList();
    final unsaved = selected
        .where((index) => !_isSaved(index, paths![index]))
        .toList();
    final alreadySaved = selected.length - unsaved.length;
    final allSaved = alreadySaved > 0 && unsaved.isEmpty;
    final fileActionsBusy =
        _checkingSelection || state.savingToGallery || state.sharingExports;
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
        uncertain ? l10n.mobileExportStopUnconfirmed : l10n.mobileExportFailed,
        uncertain ? LucideIcons.circleAlert : LucideIcons.circleX,
        uncertain
            ? Theme.of(context).colorScheme.onSurfaceVariant
            : Theme.of(context).colorScheme.error,
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
                    if (uncertain)
                      _UncertainExportNotice(state: state, forExport: true),
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
                    if (saveFailure != null)
                      _ExportFailureNotice(
                        key: const ValueKey('export-save-error'),
                        title: l10n.mobileExportSaveError,
                        failure: saveFailure,
                      ),
                    if (shareFailure != null)
                      _ExportFailureNotice(
                        key: const ValueKey('export-share-error'),
                        title: l10n.mobileExportShareError,
                        failure: shareFailure,
                      ),
                    if (_newlyMissing.isNotEmpty)
                      ExpansionTile(
                        key: const ValueKey('export-missing-files'),
                        tilePadding: EdgeInsets.zero,
                        initiallyExpanded: true,
                        title: Text(l10n.mobileExportMissingFilesDetails),
                        children: [
                          _InlineNotice(
                            error: true,
                            message: l10n.mobileExportUnavailableFile(
                              _newlyMissing
                                  .map((index) => files[index].name)
                                  .join('\n'),
                            ),
                          ),
                        ],
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
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.mobileExportFileCount(count),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          if (count > 1)
                            IconButton(
                              onPressed: () =>
                                  setState(() => _showFiles = !_showFiles),
                              tooltip: context.bheText(
                                _showFiles ? '收起' : '展开',
                              ),
                              icon: Icon(
                                _showFiles
                                    ? LucideIcons.chevronUp
                                    : LucideIcons.chevronDown,
                              ),
                            ),
                        ],
                      ),
                    if (count > 1 && paths != null)
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          Text(
                            l10n.mobileExportSelected(selected.length, count),
                          ),
                          TextButton(
                            onPressed:
                                available.length == selected.length ||
                                    fileActionsBusy
                                ? null
                                : () => setState(_unchecked.clear),
                            child: Text(l10n.mobileExportSelectAll),
                          ),
                          TextButton(
                            onPressed: selected.isEmpty || fileActionsBusy
                                ? null
                                : () => setState(
                                    () => _unchecked.addAll(available),
                                  ),
                            child: Text(l10n.mobileExportClearSelection),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              if (_showFiles)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  sliver: SliverList.builder(
                    itemCount: count,
                    itemBuilder: (context, index) {
                      final file = files[index];
                      final path = paths?[index];
                      final saved = _isSaved(index, path);
                      final enabled =
                          path != null && !_noLongerAvailable.contains(index);
                      final title = file.label != null || file.untagged
                          ? _exportLabel(context, file.label)
                          : file.name;
                      final status = paths == null
                          ? l10n.mobileExportCheckingFiles
                          : !enabled
                          ? context.bheText(saved ? '已保存到相册，请在相册查看' : '本机文件不可用')
                          : saved
                          ? l10n.mobileExportSaved
                          : null;
                      return Card(
                        child: ListTile(
                          key: ValueKey('export-file-$index'),
                          leading: Semantics(
                            label: [
                              title,
                              if (status != null) status,
                            ].join(', '),
                            child: Checkbox(
                              value: enabled && !_unchecked.contains(index),
                              onChanged: !enabled || fileActionsBusy
                                  ? null
                                  : (checked) => setState(() {
                                      checked == true
                                          ? _unchecked.remove(index)
                                          : _unchecked.add(index);
                                    }),
                            ),
                          ),
                          title: Text(title),
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
                    if (_checkingSelection)
                      Text(l10n.mobileExportCheckingFiles),
                    if (saveFailure != null)
                      Semantics(
                        liveRegion: true,
                        child: Text(l10n.mobileExportSaveError),
                      ),
                    if (shareFailure != null)
                      Semantics(
                        liveRegion: true,
                        child: Text(l10n.mobileExportShareError),
                      ),
                    if (_newlyMissing.isNotEmpty)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          l10n.mobileExportMissingFiles(_newlyMissing.length),
                        ),
                      ),
                    if (paths != null && selected.isEmpty)
                      Text(l10n.mobileExportSelectFiles),
                    if (alreadySaved > 0 && !allSaved)
                      Text(l10n.mobileExportSavedSkipped(alreadySaved)),
                    if (Platform.isAndroid &&
                        _didSave &&
                        state.gallerySaveNotice != null)
                      Text(l10n.mobileExportSavedToday),
                    if (allSaved)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: !canRun || fileActionsBusy
                              ? null
                              : () => unawaited(_save(selected)),
                          child: Text(l10n.mobileExportSaveAgain),
                        ),
                      ),
                    _ResultActions(
                      shareFocus: _shareFocus,
                      onShare: selected.isEmpty || fileActionsBusy
                          ? null
                          : (origin) => _share(selected, origin),
                      saveText: allSaved
                          ? l10n.mobileExportSaved
                          : unsaved.isNotEmpty && saveFailure != null
                          ? l10n.mobileExportTrySaveRemaining(unsaved.length)
                          : l10n.mobileSaveExportCount(unsaved.length),
                      onSave: unsaved.isEmpty || !canRun || fileActionsBusy
                          ? null
                          : () => unawaited(_save(unsaved)),
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
    this.localPath,
  });
  final String name;
  final String? localPath;
  final String? label;
  final bool untagged;
  final ExportHistoryFile? historical;
}

class _ResultActions extends StatelessWidget {
  const _ResultActions({
    required this.shareFocus,
    required this.onShare,
    required this.onSave,
    required this.saveText,
  });
  final FocusNode shareFocus;
  final Future<void> Function(Rect)? onShare;
  final VoidCallback? onSave;
  final String saveText;

  @override
  Widget build(BuildContext context) {
    final share = Builder(
      builder: (context) => OutlinedButton(
        key: const ValueKey('export-share'),
        focusNode: shareFocus,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        ),
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
