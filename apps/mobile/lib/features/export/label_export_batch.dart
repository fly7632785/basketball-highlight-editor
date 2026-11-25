part of '../../mobile_app_state.dart';

extension MobileLabelExport on MobileAppState {
  Future<void> exportByLabels({
    ExportScope scope = ExportScope.all,
    ExportFraming framing = ExportFraming.original,
  }) async {
    final run = _beginExport(framing, scope, MobileOutputMode.labels);
    if (run == null) return;
    _batchExport = true;
    final watch = Stopwatch()..start();
    final id = project.id, session = _projectSession;
    bool current() =>
        !_disposed &&
        project.id == id &&
        _projectSession == session &&
        _exportRun == run;
    bool eligible() => current() && !exportCancelled && !_batchStopRequested;
    var groupCommitted = false;
    var cleanupUncertain = false;
    Directory? batchDirectory;
    try {
      if (!await _matchesProjectVideo(applyResult: eligible)) {
        if (eligible()) {
          errorMessage ??= '请先重新选择原视频。';
          _notifyLabelExport();
        }
        return;
      }
      if (!eligible()) return;
      await _mutations.drained;
      if (!eligible()) return;
      final selected = scope.select(
        project.candidates,
        MobileOutputMode.labels,
      );
      final groups = labelExportGroups(selected, scope: scope);
      if (groups.isEmpty) {
        errorMessage = '没有可导出的片段';
        _notifyLabelExport();
        return;
      }
      exportBatchTotal = groups.length;
      _historyActiveMode = 'labels';
      _historyPlannedCount = groups.length;
      final parent = Directory(await _projectPath(id, area: 'exports'));
      await parent.create(recursive: true);
      final batch = await parent.createTemp('labels_');
      batchDirectory = batch;
      if (!eligible()) return;
      _exportPreflight = false;
      final engine = framing == ExportFraming.portrait916
          ? _portraitEngine
          : exportEngine;
      Future<void> exportGroups() async {
        for (var index = 0; index < groups.length; index++) {
          if (!eligible()) break;
          final group = groups[index];
          final ordered = [...group.candidates]
            ..sort((a, b) => a.startMs.compareTo(b.startMs));
          final path = '${batch.path}/group_${index + 1}.mp4';
          groupCommitted = false;
          _mergeCommitted = false;
          var first = true;
          final updates = framing == ExportFraming.portrait916
              ? _portraitEngine.exportPortrait(
                  video: project.video!,
                  candidates: ordered,
                  outputDirectory: batch.path,
                  mergedPath: path,
                  batchGroup: index + 1,
                )
              : engine is NativeMediaExportEngine
              ? engine.mergeClipsInBatch(
                  video: project.video!,
                  candidates: ordered,
                  outputPath: path,
                  batchGroup: index + 1,
                )
              : engine.mergeClips(
                  video: project.video!,
                  candidates: ordered,
                  outputPath: path,
                );
          await for (final update in updates) {
            if (!current()) return;
            if (first && exportCancelled && !update.committed) {
              await exportEngine.cancel();
            }
            first = false;
            if (!current()) return;
            if (update.committed ||
                (update.outputPath != null && !exportCancelled)) {
              groupCommitted = true;
              _mergeCommitted = true;
              exportCancelled = false;
            }
            _applyPortraitProgress(update);
            exportAudioSkipped |= update.skippedAudioTracks.isNotEmpty;
            exportMergedOverlapCount =
                (exportMergedOverlapCount ?? 0) +
                (update.mergedOverlapCount ?? 0);
            progress = (index + update.progress.clamp(0, 1)) / groups.length;
            progressMessage =
                '正在合成标签 ${index + 1}/${groups.length}：${group.label}';
            if (update.outputPath != null &&
                !exportedPaths.contains(update.outputPath)) {
              exportedPaths = [...exportedPaths, update.outputPath!];
              exportBatchFiles = [
                ...exportBatchFiles,
                LabelExportFile(group.label, update.outputPath!),
              ];
            }
            _notifyLabelExport();
          }
          if (!current() || _batchStopRequested || exportCancelled) break;
        }
      }

      if (engine is NativeMediaExportEngine) {
        await engine.withMergeBatch(
          exportGroups,
          onWaiting: () {
            if (current()) {
              progressMessage = '正在结束上一次导出';
              _notifyLabelExport();
            }
          },
        );
      } else {
        await exportGroups();
      }
      if (!current()) return;
      if (exportedPaths.isNotEmpty) {
        final saved = await _submitProjectChange(
          (p) => p.copyWith(lastExportDurationMs: watch.elapsedMilliseconds),
          inverse: (before) => _restoreOperationFields(before, {'export'}),
          operation: 'export',
        );
        if (saved) MobileDiagnostics.instance.event('operation.completed');
      }
      if (!current()) return;
      progressMessage = exportBatchFiles.length == exportBatchTotal
          ? '按标签合成完成'
          : '部分导出已完成';
      _notifyLabelExport();
    } on Object catch (error, stack) {
      if (error is ExportDrainTimeout) {
        cleanupUncertain = true;
        _markExportUncertain(error, stack);
      }
      if (current()) {
        if (error is ExportDrainTimeout && groupCommitted) {
          if (await _submitProjectChange(
            (p) => p.copyWith(lastExportDurationMs: watch.elapsedMilliseconds),
            inverse: (before) => _restoreOperationFields(before, {'export'}),
            operation: 'export',
          )) {
            MobileDiagnostics.instance.event('operation.completed');
          }
        } else if (!_batchStopRequested && !exportCancelled) {
          recordDiagnosticFailure(error, stack, operation: 'export');
        }
        _notifyLabelExport();
      } else {
        MobileDiagnostics.instance.error(error, stack, operation: 'export');
      }
    } finally {
      watch.stop();
      if (current() && exportedPaths.isNotEmpty) {
        await _recordExportHistory(
          mode: 'labels',
          plannedCount: exportBatchTotal,
          durationMs: watch.elapsedMilliseconds,
          paths: List.of(exportedPaths),
          expectedRun: run,
          names: {
            for (final file in exportBatchFiles) file.path: file.label ?? '未标记',
          },
          untaggedPaths: {
            for (final file in exportBatchFiles)
              if (file.label == null) file.path,
          },
        );
      }
      if (batchDirectory != null && !cleanupUncertain) {
        try {
          if (await batchDirectory.exists() &&
              await batchDirectory.list().isEmpty) {
            await batchDirectory.delete();
          }
        } on Object catch (error, stack) {
          MobileDiagnostics.instance.error(
            error,
            stack,
            operation: 'export.cleanup',
          );
        }
      }
      if (current()) {
        _exportDrainTimer?.cancel();
        exporting = false;
        _exportPreflight = false;
        _batchExport = false;
        if (portraitRequest != null) portraitExportError = errorMessage;
        _notifyLabelExport();
      }
    }
  }
}
