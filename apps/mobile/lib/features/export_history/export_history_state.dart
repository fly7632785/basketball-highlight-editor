part of '../../mobile_app_state.dart';

extension MobileExportHistory on MobileAppState {
  Future<String?> exportHistoryFilePath(ExportHistoryFile file) async {
    if (path.isAbsolute(file.relativePath)) return null;
    final id = project.id, session = _projectSession;
    try {
      final root = await _projectPath(id, area: 'exports');
      final candidate = path.normalize(path.join(root, file.relativePath));
      if (!path.isWithin(root, candidate)) return null;
      final actual = File(candidate);
      if (!await actual.exists()) return null;
      final resolvedRoot = await Directory(root).resolveSymbolicLinks();
      final resolvedFile = await actual.resolveSymbolicLinks();
      if (_disposed || project.id != id || _projectSession != session) {
        return null;
      }
      return path.isWithin(resolvedRoot, resolvedFile) ? resolvedFile : null;
    } on Object catch (error, stack) {
      MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'export.history.path',
      );
      return null;
    }
  }

  Future<Directory> _newExportDirectory(String id, String prefix) async {
    final root = Directory(await _projectPath(id, area: 'exports'));
    await root.create(recursive: true);
    return root.createTemp(prefix);
  }

  Future<void> _removeEmptyExportDirectory(Directory? directory) async {
    if (directory == null || hasUncertainExport) return;
    try {
      if (await directory.exists() && await directory.list().isEmpty) {
        await directory.delete();
      }
    } on Object catch (error, stack) {
      MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'export.cleanup',
      );
    }
  }

  Future<void> _recordExportHistory({
    required String mode,
    required int plannedCount,
    required int durationMs,
    required List<String> paths,
    required int expectedRun,
    bool allowRunChange = false,
    Map<String, String>? names,
    Set<String> untaggedPaths = const {},
  }) async {
    if (plannedCount <= 0 || paths.isEmpty) return;
    final id = project.id, session = _projectSession;
    final createdAt = DateTime.now().toUtc();
    final previousError = errorMessage;
    final previousDiagnostic = diagnosticError;
    bool current() =>
        !_disposed &&
        project.id == id &&
        _projectSession == session &&
        (allowRunChange || _exportRun == expectedRun);
    try {
      final root = await _projectPath(id, area: 'exports');
      if (!current()) return;
      final files = <ExportHistoryFile>[];
      for (final value in paths) {
        final normalized = path.normalize(value);
        if (!path.isAbsolute(normalized) || !path.isWithin(root, normalized)) {
          continue;
        }
        files.add(
          ExportHistoryFile(
            name: names?[value] ?? path.basename(value),
            relativePath: path.relative(normalized, from: root),
            untagged: untaggedPaths.contains(value),
          ),
        );
      }
      if (files.isEmpty) return;
      final entry = ExportHistoryEntry(
        id: '${createdAt.microsecondsSinceEpoch}_$expectedRun',
        createdAt: createdAt,
        mode: mode,
        plannedCount: plannedCount,
        durationMs: durationMs,
        files: files,
      );
      final saved = await _submitProjectChange(
        (value) {
          final entries = [entry, ...value.exportHistory]
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return value.copyWith(exportHistory: entries.take(50).toList());
        },
        inverse: (before) =>
            (value) => value.copyWith(exportHistory: before.exportHistory),
        operation: 'export.history',
      );
      if (!saved && current()) {
        exportHistoryDiagnostic = diagnosticError;
        diagnosticError = previousDiagnostic ?? exportHistoryDiagnostic;
        errorMessage = previousError;
        exportHistoryWarning = '视频已导出，历史记录保存失败。';
        _notifyHistory();
      }
    } on Object catch (error, stack) {
      if (current()) {
        recordDiagnosticFailure(error, stack, operation: 'export.history');
        exportHistoryDiagnostic = diagnosticError;
        diagnosticError = previousDiagnostic ?? exportHistoryDiagnostic;
        errorMessage = previousError;
        exportHistoryWarning = '视频已导出，历史记录保存失败。';
        _notifyHistory();
      } else {
        MobileDiagnostics.instance.error(
          error,
          stack,
          operation: 'export.history',
        );
      }
    }
  }

  void _recordTimedOutPartialHistory(int run) {
    final mode = _historyActiveMode;
    final started = _historyExportStartedAt;
    if (mode == null ||
        started == null ||
        _historyPlannedCount <= 0 ||
        exportedPaths.isEmpty) {
      return;
    }
    final paths = List<String>.of(exportedPaths);
    final names = {
      for (final file in exportBatchFiles) file.path: file.label ?? '未标记',
    };
    unawaited(
      _recordExportHistory(
        mode: mode,
        plannedCount: _historyPlannedCount,
        durationMs: DateTime.now()
            .difference(started)
            .inMilliseconds
            .clamp(0, 1000000000000000),
        paths: paths,
        expectedRun: run,
        allowRunChange: true,
        names: names,
        untaggedPaths: {
          for (final file in exportBatchFiles)
            if (file.label == null) file.path,
        },
      ),
    );
  }

  Future<void> _markHistoryGallerySaved(
    String value, {
    required String id,
    required int session,
  }) async {
    bool current() =>
        !_disposed && project.id == id && _projectSession == session;
    try {
      if (!current() ||
          !path.isAbsolute(value) ||
          project.exportHistory.isEmpty)
        return;
      final root = await _projectPath(id, area: 'exports');
      final resolvedRoot = await Directory(root).resolveSymbolicLinks();
      if (!current()) return;
      final normalized = path.normalize(value);
      final relative = path.isWithin(root, normalized)
          ? path.relative(normalized, from: root)
          : path.isWithin(resolvedRoot, normalized)
          ? path.relative(normalized, from: resolvedRoot)
          : null;
      if (relative == null) return;
      if (!project.exportHistory.any(
        (entry) => entry.files.any((file) => file.relativePath == relative),
      )) {
        return;
      }
      final saved = await _submitProjectChange(
        (project) => project.copyWith(
          exportHistory: [
            for (final entry in project.exportHistory)
              entry.copyWith(
                files: [
                  for (final file in entry.files)
                    file.relativePath == relative
                        ? file.copyWith(savedToGallery: true)
                        : file,
                ],
              ),
          ],
        ),
        inverse: (before) =>
            (project) => project.copyWith(exportHistory: before.exportHistory),
        operation: 'export.history.gallery',
      );
      if (!saved && current()) {
        exportHistoryDiagnostic = diagnosticError;
        errorMessage = null;
        exportHistoryWarning = '已保存到相册，历史记录更新失败。';
        _notifyHistory();
      }
    } on Object catch (error, stack) {
      if (current()) {
        recordDiagnosticFailure(
          error,
          stack,
          operation: 'export.history.gallery',
        );
        exportHistoryDiagnostic = diagnosticError;
        errorMessage = null;
        exportHistoryWarning = '已保存到相册，历史记录更新失败。';
        _notifyHistory();
      } else {
        MobileDiagnostics.instance.error(
          error,
          stack,
          operation: 'export.history.gallery',
        );
      }
    }
  }
}
