import '../src/generated/bhe_localizations.dart';
import 'package:flutter/widgets.dart';

/// Translates legacy status/error text that is persisted by the engine or
/// emitted by native plugins before the UI localization layer can see it.
/// New user-facing copy should use an ARB getter instead.
extension BheLocalizedText on BheLocalizations {
  String text(String source) {
    if (!localeName.startsWith('en')) return source;
    final direct = _englishText[source];
    if (direct != null) return direct;
    final exceptionPrefix = 'Exception: ';
    final normalized = source.startsWith(exceptionPrefix)
        ? source.substring(exceptionPrefix.length)
        : source;
    final normalizedDirect = _englishText[normalized];
    if (normalizedDirect != null) return normalizedDirect;
    final newline = normalized.indexOf('\n');
    if (newline >= 0) {
      final first = normalized.substring(0, newline);
      final translated = text(first);
      if (translated != first) {
        return '$translated${normalized.substring(newline)}';
      }
    }
  final codedError = RegExp(r'^([A-Z][A-Z0-9_]+): (.+)$').firstMatch(normalized);
  if (codedError != null) {
    return '${codedError.group(1)}: ${text(codedError.group(2)!)}';
  }
  final errorWithDetail = RegExp(r'^(视频预览加载失败|自动切换标记画面失败|标记画面切换失败|任务状态加载失败|导出记录加载失败|关闭项目失败|退出前保存项目失败|候选片段加载失败|开始记录审核耗时失败)：(.+)$').firstMatch(normalized);
  if (errorWithDetail != null) {
    const labels = <String, String>{
      '视频预览加载失败': 'Video preview failed',
      '自动切换标记画面失败': 'Could not switch the marked frame',
      '标记画面切换失败': 'Could not switch the marked frame',
      '任务状态加载失败': 'Could not load task status',
      '导出记录加载失败': 'Could not load export history',
      '关闭项目失败': 'Could not close the project',
      '退出前保存项目失败': 'Could not save the project before exit',
      '候选片段加载失败': 'Could not load candidate clips',
      '开始记录审核耗时失败': 'Could not start review timing',
    };
    return '${labels[errorWithDetail.group(1)]}: ${text(errorWithDetail.group(2)!)}';
  }
  final engineDetail = RegExp(r'^(无法向 Engine 发送请求|请求处理超时)：(.+)$').firstMatch(normalized);
  if (engineDetail != null) {
    final label = engineDetail.group(1) == '请求处理超时'
        ? 'Request timed out'
        : 'Could not send the request to Engine';
    return '$label: ${text(engineDetail.group(2)!)}';
  }
  final exited = RegExp(r'^Engine 进程已退出（exitCode=(\d+)）(?:[：:](.+))?$').firstMatch(normalized);
  if (exited != null) {
    return 'Engine process exited (exitCode=${exited.group(1)})${exited.group(2) == null ? '' : ': ${text(exited.group(2)!.trim())}'}';
  }
    final missingId = RegExp(r'^Engine 返回的 (.+) 缺少 id$').firstMatch(normalized);
    if (missingId != null) {
      return 'Engine response for ${missingId.group(1)} is missing an id';
    }
    final dynamicText = _translateDynamic(normalized);
    if (dynamicText != null) return dynamicText;
    for (final entry in _englishText.entries) {
      if (entry.key.endsWith('：') && normalized.startsWith(entry.key)) {
        return '${entry.value}${normalized.substring(entry.key.length)}';
      }
    }
    return source;
  }
}

/// Transitional bridge for copy that is assembled by the current UI. It lets
/// persisted/native messages and the remaining legacy labels follow the
/// selected locale while they are moved to ARB getters incrementally.
extension BheBuildContextText on BuildContext {
  String bheText(String source) {
    final l10n = Localizations.of<BheLocalizations>(this, BheLocalizations);
    return l10n?.text(source) ?? source;
  }
}

String? _translateDynamic(String source) {
  final exportElapsed = RegExp(r'^已用 (\d+:\d+(?::\d+)?)$').firstMatch(source);
  if (exportElapsed != null) return 'Elapsed ${exportElapsed.group(1)}';
  final savedPath = RegExp(r'^项目(可能)?保存在：([\s\S]+)，可在首页「打开项目」选择该文件夹。$').firstMatch(source);
  if (savedPath != null) {
    final prefix = savedPath.group(1) == null ? 'Project saved at' : 'Project may have been saved at';
    return '$prefix: ${savedPath.group(2)}. Select this folder using “Open project” on the home screen.';
  }
  final historyMore = RegExp(r'^查看全部 (\d+) 条$').firstMatch(source);
  if (historyMore != null) return 'View all ${historyMore.group(1)} entries';
  final labelBatch = RegExp(r'^已完成 (\d+)/(\d+) 个标签$').firstMatch(source);
  if (labelBatch != null) return '${labelBatch.group(1)}/${labelBatch.group(2)} labels completed';
  final labelProgress = RegExp(r'^正在合成标签 (\d+)/(\d+)：(.+)$').firstMatch(source);
  if (labelProgress != null) return 'Merging label ${labelProgress.group(1)}/${labelProgress.group(2)}: ${labelProgress.group(3) == '未标记' ? 'Unlabelled' : labelProgress.group(3)}';
  final mobileFormat = RegExp(r'^这个视频的格式（(.+)）手机无法处理。$').firstMatch(source);
  if (mobileFormat != null) return 'This phone cannot process this video format (${mobileFormat.group(1)}).';

  final gameStatsSummary = RegExp(r'^保留 (\d+) 个(?: · 命中率估算 (\d+)%)?$').firstMatch(source);
  if (gameStatsSummary != null) {
    final rate = gameStatsSummary.group(2);
    return rate == null
        ? '${gameStatsSummary.group(1)} kept'
        : '${gameStatsSummary.group(1)} kept · est. hit rate $rate%';
  }
  final untaggedReminder = RegExp(r'^还有 (\d+) 个片段未标标签$').firstMatch(source);
  if (untaggedReminder != null) {
    final n = untaggedReminder.group(1);
    return n == '1' ? '1 clip is still untagged' : '$n clips are still untagged';
  }
  final historyPartial = RegExp(r'^部分完成 (\d+)/(\d+)$').firstMatch(source);
  if (historyPartial != null) {
    return 'Partial ${historyPartial.group(1)}/${historyPartial.group(2)}';
  }
  final historyDone = RegExp(r'^全部完成 (\d+)$').firstMatch(source);
  if (historyDone != null) return 'Done · ${historyDone.group(1)}';
  final excludedSplit = RegExp(r'^手动 (\d+) · 复核 (\d+)$').firstMatch(source);
  if (excludedSplit != null) {
    return 'Manual ${excludedSplit.group(1)} · Rim ${excludedSplit.group(2)}';
  }
  final reducedClips = RegExp(r'^合并后减少了 (\d+) 个片段$').firstMatch(source);
  if (reducedClips != null) {
    return 'Merging reduced the clip count by ${reducedClips.group(1)}.';
  }
  final mergedOverlap = RegExp(r'^有 (\d+) 个重叠片段已合并为一段$').firstMatch(source);
  if (mergedOverlap != null) {
    return '${mergedOverlap.group(1)} overlapping clips merged into continuous segments';
  }
  final minutes = RegExp(r'^(?:第 (\d+) 段 )?(\d+)–(\d+) 分钟$').firstMatch(source);
  if (minutes != null) {
    final range = '${minutes.group(2)}–${minutes.group(3)} min';
    return minutes.group(1) == null ? range : 'Part ${minutes.group(1)} $range';
  }
  final missingFile = RegExp(r'^找不到文件或文件夹：(.+)$').firstMatch(source);
  if (missingFile != null) return 'File or folder not found: ${missingFile.group(1)}';
  final accessDenied = RegExp(r'^没有权限访问：(.+)$').firstMatch(source);
  if (accessDenied != null) return 'Access denied: ${accessDenied.group(1)}';
  final newVersion = RegExp(r'^(发现新版本|新版本) v(.+)$').firstMatch(source);
  if (newVersion != null) {
    return '${newVersion.group(1) == '发现新版本' ? 'New version available' : 'New version'}: v${newVersion.group(2)}';
  }
  final latest = RegExp(r'^已经是最新版本（v(.+)）$').firstMatch(source);
  if (latest != null) return 'You are on the latest version (v${latest.group(1)})';
  final downloaded = RegExp(r'^已下载 (\d+) / (\d+) MB$').firstMatch(source);
  if (downloaded != null) {
    return 'Downloaded ${downloaded.group(1)} / ${downloaded.group(2)} MB';
  }
  final httpFailure = RegExp(r'^(获取更新信息失败|下载失败)（HTTP (\d+)）$').firstMatch(source);
  if (httpFailure != null) {
    return '${httpFailure.group(1) == '下载失败' ? 'Download failed' : 'Could not get update information'} (HTTP ${httpFailure.group(2)})';
  }
  final segment = RegExp(r'^第 (\d+) 段$').firstMatch(source);
  if (segment != null) return 'Part ${segment.group(1)}';
  final partCount = RegExp(r'^共 (\d+) 段$').firstMatch(source);
  if (partCount != null) return '${partCount.group(1)} parts';
  final segmentDone = RegExp(r'^第 (\d+) 段分析完成$').firstMatch(source);
  if (segmentDone != null) return 'Part ${segmentDone.group(1)} analysed';
  final segmentStart = RegExp(r'^正在启动第 (\d+) 段分析…$').firstMatch(source);
  if (segmentStart != null) return 'Starting part ${segmentStart.group(1)}…';
  final adding = RegExp(r'^正在添加第 (\d+)/(\d+) 段视频…$').firstMatch(source);
  if (adding != null) {
    return 'Adding part ${adding.group(1)} of ${adding.group(2)}…';
  }
  final added = RegExp(r'^已添加 (\d+) 段视频$').firstMatch(source);
  if (added != null) return 'Added ${added.group(1)} videos';
  final allCandidates = RegExp(r'^全部 (\d+) 个候选片段$').firstMatch(source);
  if (allCandidates != null)
    return 'All ${allCandidates.group(1)} candidate clips';
  final reviewProgress = RegExp(r'^已审核 (\d+) / (\d+)$').firstMatch(source);
  if (reviewProgress != null) {
    return 'Reviewed ${reviewProgress.group(1)} / ${reviewProgress.group(2)}';
  }
  final shownCandidates = RegExp(r'^显示 (\d+) / (\d+)$').firstMatch(source);
  if (shownCandidates != null) {
    return 'Showing ${shownCandidates.group(1)} / ${shownCandidates.group(2)}';
  }
  final filteredCandidates = RegExp(r'^当前筛选的 (\d+) 个候选片段$').firstMatch(source);
  if (filteredCandidates != null) {
    return '${filteredCandidates.group(1)} filtered candidate clips';
  }
  final overwriteFiltered = RegExp(
    r'^将覆盖筛选出的 (\d+) 个片段，其中 (\d+) 个曾手动调整。$',
  ).firstMatch(source);
  if (overwriteFiltered != null) {
    return 'Overwrite ${overwriteFiltered.group(1)} filtered clips; ${overwriteFiltered.group(2)} were manually adjusted.';
  }
  final candidateCount = RegExp(r'^候选 (\d+)$').firstMatch(source);
  if (candidateCount != null) return 'Candidates ${candidateCount.group(1)}';
  final applyToClips = RegExp(r'^应用到 (\d+) 个片段$').firstMatch(source);
  if (applyToClips != null) return 'Apply to ${applyToClips.group(1)} clips';
  final batchRangeSummary = RegExp(
    r'^将更新 (\d+) 个片段，保留 (\d+) 个手动调整片段。$',
  ).firstMatch(source);
  if (batchRangeSummary != null) {
    return 'Update ${batchRangeSummary.group(1)} clips; keep ${batchRangeSummary.group(2)} manually adjusted clips.';
  }
  final skippedBatchRange = RegExp(
    r'^已更新片段时长，(\d+) 个片段靠近视频结尾未调整$',
  ).firstMatch(source);
  if (skippedBatchRange != null) {
    return 'Clip duration updated; ${skippedBatchRange.group(1)} clips near the end of the video were left unchanged';
  }
  final overwriteBatchRangeSummary = RegExp(
    r'^将覆盖全部 (\d+) 个片段，其中 (\d+) 个曾手动调整。$',
  ).firstMatch(source);
  if (overwriteBatchRangeSummary != null) {
    return 'Overwrite all ${overwriteBatchRangeSummary.group(1)} clips; ${overwriteBatchRangeSummary.group(2)} were manually adjusted.';
  }
  final itemCount = RegExp(r'^(\d+) 个$').firstMatch(source);
  if (itemCount != null) return '${itemCount.group(1)} items';
  final reviewCount = RegExp(r'^审核 (\d+)/(\d+)$').firstMatch(source);
  if (reviewCount != null)
    return 'Review ${reviewCount.group(1)}/${reviewCount.group(2)}';
  final includedCount = RegExp(r'^(?:已选|保留) (\d+) / (\d+)$').firstMatch(source);
  if (includedCount != null) {
    return 'Included ${includedCount.group(1)} / ${includedCount.group(2)}';
  }
  final exportCount = RegExp(r'^导出 (\d+) 个片段$').firstMatch(source);
  if (exportCount != null) return 'Export ${exportCount.group(1)} clips';
  final exported = RegExp(r'^已导出 (\d+) 个片段$').firstMatch(source);
  if (exported != null) return 'Exported ${exported.group(1)} clips';
  final deleteCurrent = RegExp(r'^“(.+)”及其审核记录会从本机移除。$').firstMatch(source);
  if (deleteCurrent != null) {
    return '“${deleteCurrent.group(1)}” and its review records will be removed from this device.';
  }
  final deletePlayer = RegExp(r'^删除“(.+)”后，已标记的候选会变为未标记。$').firstMatch(source);
  if (deletePlayer != null) {
    return 'Deleting “${deletePlayer.group(1)}” will clear the tag from marked candidates.';
  }
  final exportPlayer = RegExp(r'^导出 (.+) 的片段$').firstMatch(source);
  if (exportPlayer != null) return 'Export ${exportPlayer.group(1)} clips';
  final mergePlayer = RegExp(r'^合并导出 (.+) 的片段$').firstMatch(source);
  if (mergePlayer != null) return 'Merge ${mergePlayer.group(1)} clips';
  final currentPlayer = RegExp(r'^球员：(.+)$').firstMatch(source);
  if (currentPlayer != null) return 'Player: ${currentPlayer.group(1)}';
  final pointCount = RegExp(r'^轨迹点 (\d+) 个$').firstMatch(source);
  if (pointCount != null) return 'Trajectory points: ${pointCount.group(1)}';
  final seconds = RegExp(r'^(\d+(?:\.\d+)?) 秒$').firstMatch(source);
  if (seconds != null) return '${seconds.group(1)} sec';
  final savingPhoto = RegExp(r'^正在保存到相册 (\d+)/(\d+)$').firstMatch(source);
  if (savingPhoto != null) {
    return 'Saving to photos ${savingPhoto.group(1)}/${savingPhoto.group(2)}';
  }
  final savedPhotos = RegExp(r'^已保存 (\d+) 个片段到相册$').firstMatch(source);
  if (savedPhotos != null)
    return 'Saved ${savedPhotos.group(1)} clips to photos';
  final decodeIncomplete = RegExp(r'^视频解码不完整 (\d+)/(\d+)$').firstMatch(source);
  if (decodeIncomplete != null) {
    return 'Video decoding incomplete ${decodeIncomplete.group(1)}/${decodeIncomplete.group(2)}';
  }
  final processing = RegExp(r'^处理 (.+)$').firstMatch(source);
  if (processing != null) return 'Processing ${processing.group(1)}';
  final exportingRange = RegExp(r'^正在导出 (\d+)-(\d+)/(\d+)$').firstMatch(source);
  if (exportingRange != null) {
    return 'Exporting ${exportingRange.group(1)}-${exportingRange.group(2)}/${exportingRange.group(3)}';
  }
  final exportedRange = RegExp(r'^已导出 (\d+)/(\d+)$').firstMatch(source);
  if (exportedRange != null) {
    return 'Exported ${exportedRange.group(1)}/${exportedRange.group(2)}';
  }
  final heavyImport = RegExp(
    r'^(.+)。若只是想减少等待，建议先压缩为 1080p MP4 再导入；分析期间不要关闭应用。$',
  ).firstMatch(source);
  if (heavyImport != null) {
    return '${_localizeVideoLabel(heavyImport.group(1)!)}. To reduce waiting, compress it to a 1080p MP4 before importing; keep the app open during analysis.';
  }
  final elevatedImport = RegExp(
    r'^(.+)。建议保持电源和磁盘空间充足，想加快速度可先压缩后导入。$',
  ).firstMatch(source);
  if (elevatedImport != null) {
    return '${_localizeVideoLabel(elevatedImport.group(1)!)}. Keep the device powered and ensure enough disk space; compress the video first to speed things up.';
  }
  if (source == '分析会在本地进行，耗时主要取决于视频时长、分辨率和文件码率。') {
    return 'Analysis runs locally. Time depends mainly on video length, resolution, and bitrate.';
  }
  final exportSummary = RegExp(
    r'^(合并导出|分别导出|按标签导出) · (\d+) 个片段$',
  ).firstMatch(source);
  if (exportSummary != null) {
    final mode = switch (exportSummary.group(1)) {
      '合并导出' => 'Merged export',
      '按标签导出' => 'Per-tag export',
      _ => 'Separate exports',
    };
    return '$mode · ${exportSummary.group(2)} clips';
  }
  final exportProcessing = RegExp(r'^(?:(.+) · )?处理 (.+)$').firstMatch(source);
  if (exportProcessing != null) {
    final prefix = exportProcessing.group(1);
    final detail = 'Processing ${_englishDuration(exportProcessing.group(2)!)}';
    return prefix == null ? detail : '$prefix · $detail';
  }
  final applyConfig = RegExp(
    r'^当前已有 (\d+) 个候选片段。应用后会按新配置重新生成候选，原始视频不会被删除。$',
  ).firstMatch(source);
  if (applyConfig != null) {
    return 'There are ${applyConfig.group(1)} existing candidate clips. Applying the new setup will regenerate them; the source video will not be deleted.';
  }
  final clipRange = RegExp(r'^片段 (.+) - (.+) · 时长 (.+)$').firstMatch(source);
  if (clipRange != null) {
    return 'Clip ${clipRange.group(1)} - ${clipRange.group(2)} · Duration ${_englishDuration(clipRange.group(3)!)}';
  }
  final candidateAria = RegExp(
    r'^候选 (\d+)，(.+)，(已排除|自动排除|已保留)$',
  ).firstMatch(source);
  if (candidateAria != null) {
    final status = switch (candidateAria.group(3)) {
      '已排除' => 'excluded',
      '自动排除' => 'auto-excluded',
      _ => 'included',
    };
    return 'Candidate ${candidateAria.group(1)}, ${candidateAria.group(2)}, $status';
  }
  final candidateAt = RegExp(r'^候选 (.+)$').firstMatch(source);
  if (candidateAt != null) return 'Candidate ${candidateAt.group(1)}';
  final duration = RegExp(r'^时长 (.+)$').firstMatch(source);
  if (duration != null) return 'Duration ${_englishDuration(duration.group(1)!)}';
  final selectedCount = RegExp(r'^已选 (\d+) / (\d+)$').firstMatch(source);
  if (selectedCount != null) {
    return 'Included ${selectedCount.group(1)} / ${selectedCount.group(2)}';
  }
  final timeWithUnit = RegExp(r'^(\d+) 秒$').firstMatch(source);
  if (timeWithUnit != null) return '${timeWithUnit.group(1)} sec';
  final estimatedMinutes = RegExp(r'^约 (.+) 分钟$').firstMatch(source);
  if (estimatedMinutes != null) {
    return 'About ${estimatedMinutes.group(1)} min';
  }
  final minutesWithUnit = RegExp(r'^(\d+) 分 (\d+) 秒$').firstMatch(source);
  if (minutesWithUnit != null) return '${minutesWithUnit.group(1)} min ${minutesWithUnit.group(2)} sec';
  final analysisDetail = RegExp(r'^分析详情：(.+)$').firstMatch(source);
  if (analysisDetail != null) {
    var detail = analysisDetail.group(1)!;
    const stageLabels = <String, String>{
      '代理': 'Proxy',
      '粗扫': 'Coarse scan',
      '候选': 'Candidates',
      '精筛': 'Refinement',
      '篮筐复核': 'Rim check',
      '封面': 'Covers',
      '落库': 'Save results',
    };
    for (final entry in stageLabels.entries) {
      detail = detail.replaceAll(entry.key, entry.value);
    }
    detail = detail.replaceAllMapped(
      RegExp(r'缓存命中 (\d+)'),
      (match) => 'Cache hits ${match.group(1)}',
    );
    detail = _englishDuration(detail);
    return 'Analysis details: $detail';
  }
  final cacheHit = RegExp(r'^缓存命中 (\d+)$').firstMatch(source);
  if (cacheHit != null) return 'Cache hits ${cacheHit.group(1)}';
  final processingDuration = RegExp(r'^处理 (.+)$').firstMatch(source);
  if (processingDuration != null) {
    return 'Processing ${_englishDuration(processingDuration.group(1)!)}';
  }
  final completed = RegExp(
    r'^(快速分析 · 可能漏检|标准分析) · (\d+) 个候选(?: · 用时 (.+))?$',
  ).firstMatch(source);
  if (completed != null) {
    final mode = completed.group(1) == '标准分析'
        ? 'Standard analysis'
        : 'Fast analysis · may miss clips';
    final elapsed = completed.group(3);
    return '$mode · ${completed.group(2)} candidates${elapsed == null ? '' : ' · Elapsed ${_englishDuration(elapsed)}'}';
  }
  final rangeHint = RegExp(r'^仅扫描 (.+) - (.+)。$').firstMatch(source);
  if (rangeHint != null) {
    return 'Scan only ${rangeHint.group(1)} - ${rangeHint.group(2)}.';
  }
  final startEnd = RegExp(r'^(起点|终点) (.+)$').firstMatch(source);
  if (startEnd != null) {
    return '${startEnd.group(1) == '起点' ? 'Start' : 'End'} ${startEnd.group(2)}';
  }
  final currentPosition = RegExp(r'^当前位置 (.+)$').firstMatch(source);
  if (currentPosition != null) return 'Current position ${currentPosition.group(1)}';
  final currentRegion = RegExp(r'^当前区域 (.+)$').firstMatch(source);
  if (currentRegion != null) return 'Current region ${currentRegion.group(1)}';
  final currentTime = RegExp(r'^当前 (.+)$').firstMatch(source);
  if (currentTime != null) return 'Current ${currentTime.group(1)}';
  final compactEvidence = RegExp(
    r'^置信度 (.+)  ·  轨迹 (.+)  ·  穿框 (.+)  ·  篮网 (.+)$',
  ).firstMatch(source);
  if (compactEvidence != null) {
    return 'Confidence ${compactEvidence.group(1)}  ·  Trajectory ${compactEvidence.group(2)}  ·  Crossing ${compactEvidence.group(3)}  ·  Net ${compactEvidence.group(4)}';
  }
  final stageTiming = RegExp(r'^(代理|粗扫|候选|精筛|封面|落库) (.+)$').firstMatch(source);
  if (stageTiming != null) {
    const labels = <String, String>{
      '代理': 'Proxy',
      '粗扫': 'Coarse scan',
      '候选': 'Candidates',
      '精筛': 'Refinement',
      '封面': 'Covers',
      '落库': 'Save results',
    };
    return '${labels[stageTiming.group(1)]} ${_englishDuration(stageTiming.group(2)!)}';
  }
  final stepStatus = RegExp(r'^(.+)，(已完成|未完成)$').firstMatch(source);
  if (stepStatus != null) {
    return '${stepStatus.group(1)}, ${stepStatus.group(2) == '已完成' ? 'complete' : 'incomplete'}';
  }
  final autoFrame = RegExp(r'^系统已自动选择 (.+) 作为标记画面$').firstMatch(source);
  if (autoFrame != null) return 'Automatically selected ${autoFrame.group(1)} as the marked frame';
  final videoWithoutAudio = RegExp(r'^(.+ / )无音频$').firstMatch(source);
  if (videoWithoutAudio != null) {
    return '${videoWithoutAudio.group(1)}No audio';
  }
  return null;
}

String _localizeVideoLabel(String value) => value
    .replaceAll('分辨率未知', 'unknown resolution')
    .replaceAll('文件大小未知', 'unknown file size');

String _englishDuration(String value) => value
    .replaceAll('小时', ' hr ')
    .replaceAll('分', ' min ')
    .replaceAll('秒', ' sec')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

const _englishText = <String, String>{
  '已调整': 'Edited',
  '重叠': 'Overlap',
  '诊断信息暂时不可用。': 'Diagnostics are temporarily unavailable.',
  '反馈与诊断': 'Feedback and diagnostics',
  '遇到问题时，把下面的信息发给我们。已隐藏你的用户名和文件路径。': 'If you encounter a problem, send us the information below. Your username and file paths have been hidden.',
  '已复制': 'Copied',
  '在 GitHub 反馈': 'Report on GitHub',
  '反馈': 'Feedback',
  'BHE 诊断信息': 'BHE diagnostics',
  'App 版本': 'App version',
  '安卓版本': 'Android version',
  'SDK': 'SDK',
  '厂商': 'Manufacturer',
  '手机型号': 'Device model',
  'CPU 架构': 'CPU architecture',
  '总内存': 'Total memory',
  '可用内存': 'Available memory',
  '可用存储': 'Available storage',
  '屏幕尺寸': 'Screen size',
  '语言': 'Language',
  '未知': 'Unknown',
  '当前错误': 'Current error',
  '最近的运行日志': 'Recent logs',
  '没有找到运行日志': 'No logs found',
  '运行日志暂不可用': 'Logs are temporarily unavailable',
  '复制失败，请重试。': 'Could not copy. Please try again.',
  '无法打开反馈入口，请先复制诊断信息。': 'Could not open the feedback destination. Please copy the diagnostics first.',
  '手机存储空间不足，请清理后重试。': 'Your phone is running out of storage. Free up space and try again.',
  '没有读取这个文件的权限，请重新选择。': 'There is no permission to read this file. Please choose it again.',
  '更新安装包找不到了，请重新下载。': 'The update package is missing. Please download it again.',
  '文件找不到了，请重新选择。': 'The file is missing. Please choose it again.',
  '设置无效，请检查视频范围后重试。': 'The settings are invalid. Check the video range and try again.',
  '这个视频的格式手机无法处理。': 'This phone cannot process this video format.',
  '出错了：视频分析未完成，请重试。': 'Something went wrong: video analysis did not finish. Please try again.',
  '出错了：视频导出未完成，请重试。': 'Something went wrong: video export did not finish. Please try again.',
  '出错了：更新操作未完成，请重试。': 'Something went wrong: the update did not finish. Please try again.',
  '出错了：操作未完成，请重试。': 'Something went wrong: the operation did not finish. Please try again.',
  '重命名项目': 'Rename project',
  '项目列表': 'Projects',
  '还没有项目': 'No projects yet',
  '重试': 'Retry',
  '关闭项目': 'Close project',
  '最近修改': 'Last modified',
  '当前': 'Current',
  '片段': 'Clips',
  '已分析': 'Analyzed',
  '分析中断': 'Analysis interrupted',
  '加载项目失败': 'Could not load projects',
  '删除未完成，部分文件可能已移除，请刷新项目列表。': 'Deletion did not finish. Some files may already be removed; refresh the project list.',
  '部分项目读取失败，查看反馈': 'Some projects could not be read; view diagnostics',
  '新建项目，或从最近项目中打开一个': 'Create a project or open one from recent projects.',
  '将删除项目及应用内视频副本、封面和导出文件；不会删除原视频或相册中的文件。': 'This removes the project and its app-owned video copy, cover, and exports. The original video and files in your gallery are not deleted.',
  '输出方式': 'Output mode',
  '导出历史': 'Export history',
  '暂无导出记录': 'No export history',
  '查看最近 3 条': 'Show latest 3',
  '本机文件不可用': 'Local file unavailable',
  '已保存到相册，请在相册查看': 'Saved to gallery. View it in your gallery.',
  '已保存到相册': 'Saved to gallery',
  '视频已导出，历史记录保存失败。': 'Video exported, but the history could not be saved.',
  '已保存到相册，历史记录更新失败。': 'Saved to gallery, but the history could not be updated.',
  '标签': 'Label',
  '开始导出': 'Start export',
  '每个片段原样导出': 'Export each clip separately',
  '分别保存每个保留片段': 'Save each included clip separately',
  '合并成一个视频': 'Merge into one video',
  '按时间拼成一条集锦': 'Join clips in time order',
  '按标签合成，含未标记': 'Merge by label, including unlabelled clips',
  '分享全部': 'Share all',
  '保存全部到相册': 'Save all to gallery',
  '按标签合成完成': 'Merged by label',
  '部分导出已完成': 'Some exports are complete',
  '部分完成': 'Partially complete',
  '全部完成': 'All complete',

  '重命名球员': 'Rename player',
  '名称不能为空': 'Name cannot be empty',
  '正在切换项目，请稍候': 'Switching projects, please wait',
  '本次审核未保存': 'This review was not saved',
  '操作已取消': 'Action canceled',
  '已有同名球员': 'A player with this name already exists',
  '重命名': 'Rename',
  '已标记的': 'The',
  '个片段会变成未标记。': 'tagged clips will become untagged.',

  '撤销上一步': 'Undo last action',
  '撤销': 'Undo',
  '已保留': 'Kept',
  '已设标签': 'Player assigned',
  '已改时长': 'Duration changed',
  '已改备注': 'Note changed',
  '已撤销': 'Undone',
  '保存失败，请重试': 'Could not save. Try again.',

  '检查分析引擎': 'Checking analysis engine',
  '收起': 'Collapse',
  '可多选': 'Multi-select',
  '本次导出会包含这些片段。': 'This export will include them.',
  '仍然导出': 'Export anyway',
  '展开': 'Expand',
  '从视频开头算起': 'From the start of the video',
  '保留 ÷ 候选，粗略估算，非真实命中率': 'Kept ÷ candidates. Rough estimate, not a real rate.',
  '引擎自检': 'Engine check',
  '分析引擎缺少模型加载依赖，请安装最新版本的应用，仍然不行请发送诊断信息。':
      'The analysis engine is missing a dependency required to load the model. Install the latest version of the app. If the problem persists, send us diagnostic information.',
  '分析引擎在这台电脑上无法启动（运行库初始化失败）。请先安装最新的 VC++ 运行库后重启电脑，仍然不行请把 CPU 型号和诊断信息发给我们。':
      'The analysis engine could not start on this computer (runtime initialization failed). Install the latest Visual C++ Redistributable and restart your computer. If the problem persists, send us your CPU model and diagnostic information.',
  '分析引擎在这台电脑上无法启动（运行库初始化失败）。请检查或重新安装应用，仍然不行请把系统版本、CPU 型号和诊断信息发给我们。':
      'The analysis engine could not start on this computer (runtime initialization failed). Check or reinstall the app. If the problem persists, send us your OS version, CPU model, and diagnostic information.',

  '已调整时长': 'Duration adjusted',
  '与上一段重叠': 'Overlaps the previous kept clip',
  '视频不可用': 'Video unavailable',
  '正在读取视频信息，大文件可能需要几秒。': 'Reading video information. Large files may take a few seconds.',
  '正在保存视频到本机，大文件可能需要几秒。': 'Saving the video locally. Large files may take a few seconds.',
  '正在识别篮筐区域，大文件可能需要几秒。': 'Detecting the hoop region. Large files may take a few seconds.',

  '导出成功，部分音轨无法保留': 'Export complete. Some audio tracks could not be kept.',
  '视频文件找不到了，请重新选择原视频。': 'The video file is missing. Choose the original video again.',
  '这个视频无法播放，请重新选择原视频。': 'This video cannot be played. Choose the original video again.',
  '所选视频与项目记录不一致，请选择原始视频。': 'The selected video does not match this project. Choose the original video.',
  '重新选择视频': 'Choose video again',
  '正在重新选择视频': 'Choosing the source video',
  '正在取消': 'Cancelling',

  '如果 BHE 对你有帮助': 'If BHE has been helpful',
  '如果 BHE 帮你省下了一些剪辑时间，欢迎在 GitHub 点个 Star，也可以分享给球友，让更多人知道这个项目。谢谢支持！':
      'If BHE has saved you some editing time, please consider starring it on GitHub or sharing it with your basketball friends. It helps more people discover the project. Thank you for your support!',
  '以后再说': 'Maybe later',
  '分享给球友': 'Share with friends',
  '去 GitHub 点个 Star': 'Star BHE on GitHub',
  '我在用 BHE 整理篮球比赛集锦，推荐你看看：':
      'I use BHE to put together basketball highlights. Take a look:',
  '分析完成': 'Analysis complete',
  '推理': 'Inference',
  '退出 BHE？': 'Exit BHE?',
  '分析失败': 'Analysis failed',
  '添加球员': 'Add player',
  '例如：科比、罗斯': 'For example: Kobe, Rose',
  '上一个候选': 'Previous candidate',
  '下一个候选': 'Next candidate',
  '如果方便，建议先用剪辑工具压缩后再导入。也可以继续，原视频不会被修改。':
      'If convenient, compress the video with an editing tool before importing. You can also continue; the source video will not be modified.',
  '进球前后时间会以每个候选的进球时刻为中心计算。':
      'The before and after durations are calculated around each candidate event time.',
  '关闭时自动保留手动调整的范围':
      'When off, manually adjusted ranges are kept',
  '检测区域': 'Detection regions',
  '选中': 'Include',
  '以下是自动生成候选的默认范围，审核时仍可单独调整片段。':
      'These are the default ranges for generated candidates. You can adjust clips during review.',
  '−5 秒': '−5 sec',
  '+5 秒': '+5 sec',
  '恢复默认': 'Restore defaults',
  '重新加载视频': 'Reload video',
  '补漏': 'Add missing clip',
  '重新配置分析区域和范围': 'Reconfigure analysis regions and range',
  '重新分析当前视频': 'Analyze this video again',
  '快速分析 · 可能漏检': 'Fast analysis · may miss clips',
  '快速分析未找到候选 · 可能漏检':
      'Fast analysis found no candidates · clips may have been missed',
  '候选片段没有成功恢复，请重试加载，不需要重新分析视频。':
      'Candidate clips could not be restored. Retry loading; the video does not need to be analyzed again.',
  '快速分析未计算': 'Not calculated in fast analysis',
  '快速分析不会拟合完整轨迹；切换到标准分析后才会计算。':
      'Fast analysis does not fit the full trajectory; switch to standard analysis to calculate it.',
  '标准分析未获得足够的有效轨迹点，无法可靠预测落点。':
      'Standard analysis did not find enough valid trajectory points to reliably predict the landing point.',
  '默认片段总长': 'Default clip length',
  '未设置': 'Not set',
  '已设置': 'Set',
  '自动推荐': 'Auto suggested',
  '默认扫描完整视频。播放视频后设定起点和终点，可排除热身或结束部分。':
      'The full video is scanned by default. Play the video, then set the start and end to exclude warm-ups or the ending.',
  '跳过热身或无关片段，修改会自动保存。':
      'Skip warm-ups or unrelated clips; changes are saved automatically.',
  '视频加载失败，请重新进入此步骤。':
      'The video could not be loaded. Reopen this step and try again.',
  '拖动下方两个手柄，视频会跳到正在调整的位置。':
      'Drag the two handles below to jump the video to the range being adjusted.',
  '预览加载失败，请重新生成。': 'Preview loading failed. Generate it again.',
  '起点': 'Start',
  '终点': 'End',
  '投篮区': 'Shot area',
  '篮网': 'Net',
  '还没有视频': 'No video yet',
  '切换视频来源': 'Switch video source',
  '正在查看': 'Viewing ',
  '切换到': 'Switch to ',
  '已选': 'Included',
  '全部': 'All',
  '正在恢复项目': 'Restoring project',
  '正在加载候选片段和审核记录。': 'Loading candidate clips and review records.',
  '项目数据加载失败': 'Could not load project data',
  '正在等待候选片段': 'Waiting for candidate clips',
  '分析完成后会显示候选片段。': 'Candidate clips will appear when analysis finishes.',
  '没有匹配的候选': 'No matching candidates',
  '当前筛选条件下没有片段。': 'No clips match the current filter.',
  '暂未找到候选片段': 'No candidate clips found yet',
  '还没有分析结果': 'No analysis results yet',
  '快速模式可能漏检，建议用标准模式重新分析。':
      'Fast mode may miss clips. Analyze again in standard mode.',
  '重新分析直接使用当前配置；重新配置可以修改分析范围和篮筐区域。':
      'Analyze again with the current setup, or reconfigure the analysis range and hoop region.',
  '先导入视频并完成配置，再开始分析。':
      'Import a video and finish setup before analyzing.',
  '重新配置': 'Reconfigure',
  '去导入视频': 'Import a video',
  '保留片段 (C / Enter)': 'Include clip (C / Enter)',
  '排除片段 (X / ` / Backspace)': 'Exclude clip (X / ` / Backspace)',
  '设置球员标签': 'Set player tag',
  '未标记': 'Untagged',
  '上次分析没有完成': 'The previous analysis did not finish',
  '已有候选可以继续使用，也可以重新分析': 'Existing candidates can be used or analyzed again',
  '分析进行中': 'Analysis in progress',
  '已用': 'Elapsed',
  '剩余约': 'About',
  '重试分析': 'Retry analysis',
  '上滑 / 下滑': 'Swipe up / down',
  '切换上一个 / 下一个候选片段': 'Switch to the previous / next candidate',
  '左右拖动视频': 'Drag the video left / right',
  '拖动预览位置，松手后跳转到对应时间': 'Drag the preview and release to seek to that time',
  '点击视频': 'Tap the video',
  '播放或暂停当前片段': 'Play or pause the current clip',
  '选中 / 不选': 'Include / exclude',
  '完成当前候选后自动进入下一个': 'Finish this candidate and move to the next',
  '检查视频': 'Check video',
  '准备本地模型': 'Prepare local model',
  '扫描视频': 'Scan video',
  '生成候选': 'Generate candidates',
  '精筛候选': 'Refine candidates',
  '保存结果': 'Save results',
  '分析已取消': 'Analysis cancelled',
  '正在检查视频': 'Checking video',
  '上次分析尚未确认停止，暂时不能导出。': 'The previous analysis has not been confirmed stopped. Export is unavailable.',
  '正在分析，请等待分析结束。': 'Analysis is running. Wait for it to finish.',
  '正在导出，请等待导出结束。': 'Export is running. Wait for it to finish.',
  '上次任务尚未确认结束，请先确认停止。': 'The previous task has not been confirmed stopped. Check its status first.',
  '正在准备本地模型': 'Preparing the local model',
  '上次分析尚未确认停止，暂时不能开始新分析。': 'The previous analysis may still be running. A new analysis cannot start yet.',
  '请先复制诊断信息；若仍无法确认，请在系统设置中强制停止 BHE，重新打开后检查项目。': 'Copy diagnostics first. If the status remains unknown, force stop BHE in system settings, reopen it, and check the project.',
  '正在准备本地分析': 'Preparing local analysis',
  '正在分析视频': 'Analyzing video',
  '正在生成低分辨率代理视频': 'Generating a low-resolution proxy video',
  '正在快速扫描视频': 'Scanning the video',
  '快速扫描完成，未发现候选': 'Scan complete; no candidates found',
  '正在分析候选': 'Analyzing candidates',
  '正在写入分析结果': 'Saving analysis results',
  '正在保存项目': 'Saving project',
  '正在保存视频到本机': 'Saving video on this device',
  '大文件可能需要几秒': 'Large files may take a few seconds',
  '正在准备合并导出': 'Preparing merged export',
  '正在结束上一次导出': 'Finishing the previous export',
  '上次任务尚未确认结束，暂时不能开始新的同类任务。': 'The previous task may still be running. A new task of this kind cannot start yet.',
  '请先复制诊断信息；若仍无法确认，请在系统设置中强制停止 BHE，重新打开后检查项目和已导出文件。': 'Copy the diagnostics first. If the status remains unknown, force stop BHE in system settings, reopen it, and check your project and exported files.',
  '再次尝试停止': 'Try stopping again',
  '检查停止状态': 'Check status',
  '诊断与复制': 'Diagnostics and copy',
  '上次任务仍在运行，请稍候或再次尝试停止。': 'The previous task is still running. Please wait or try stopping it again.',
  '无法确认上次任务是否停止。': 'Could not confirm whether the previous task has stopped.',
  '这个输出文件正在导出，请稍后重试。': 'This output is already being exported. Please try again later.',
  '上一次导出尚未结束，请稍后重试。': 'The previous export has not finished. Please try again later.',
  '合并导出完成': 'Merged export complete',
  '导出已取消': 'Export cancelled',
  '已导出': 'Exported',
  '已保存': 'Saved',
  '当前平台尚未注册视频导出模块。': 'Video export is not registered on this platform.',
  '当前平台尚未注册合并导出模块。': 'Merged export is not registered on this platform.',
  '当前平台尚未注册相册保存模块。': 'Photo library saving is not registered on this platform.',
  '正在取消任务并关闭项目…': 'Cancelling active tasks and closing the project…',
  '移动端分析失败': 'Mobile analysis failed',
  '移动端本地分析引擎尚未接入，请先完成 ONNX/Rust 运行时集成。':
      'The mobile analysis engine is unavailable. Complete the ONNX/Rust runtime integration first.',
  '移动端视频剪辑引擎尚未接入。': 'The mobile video editing engine is unavailable.',
  '视频检查未通过或耗时过长，请重新选择可正常播放的原视频。':
      'Video validation failed or took too long. Choose a playable source video and try again.',
  '项目包无法打开：': 'Could not open project package: ',
  '读取本地项目失败：': 'Could not read the local project: ',
  '无法恢复原生分析任务：': 'Could not recover the native analysis task: ',
  '所选视频的分辨率或时长与项目记录不一致，请选择同一段原视频。':
      'The selected video resolution or duration does not match the project record. Choose the same source video.',
  '所选视频文件与项目记录不一致，请选择原始视频。':
      'The selected video file does not match the project record. Choose the original video.',
  '请先重新选择原视频。': 'Choose the source video again first.',
  '没有符合条件的保留片段。': 'There are no included clips matching the current filter.',
  '请先选择视频并设置投篮分析区、篮网检测区。':
      'Choose a video and set the shot and net regions first.',
  '没有找到候选片段。建议检查检测区域或分析范围后重新分析。':
      'No candidate clips were found. Check the detection regions or analysis range and try again.',
  '上次分析未完成，可以重新开始。':
      'The previous analysis did not finish. You can start it again.',
  '请先等待当前操作结束或取消正在运行的任务':
      'Wait for the current operation to finish or cancel the running task first.',
  '分析期间请保持 BHE 在前台并保持屏幕亮起。锁屏或切到后台可能导致分析变慢或暂停。':
      'Keep BHE in the foreground with the screen on during analysis. Locking the screen or switching apps may slow down or pause analysis.',
  '视频已就绪': 'Video ready',
  '视频检查未通过': 'Video validation failed',
  '读取视频信息': 'Reading video information',
  '读取文件大小': 'Reading file size',
  '正在识别篮筐区域': 'Detecting the hoop region',
  '无法读取该视频，请换一个视频重试。':
      'Could not read this video. Choose another and try again.',
  '项目已打开，请重新选择原视频后继续。':
      'The project is open. Choose the source video again to continue.',
  '项目已打开，请重新选择原视频后继续':
      'The project is open. Choose the source video again to continue.',
  '项目已打开，但当前原视频与项目记录不一致，请重新选择原视频。':
      'The source video does not match the project record. Choose the original video again.',
  '未找到仍在运行的原生分析任务，可重新分析。':
      'No running native analysis task was found. You can analyze again.',
  '本地模型准备超过 60 秒，请检查存储空间后重试。':
      'Preparing the local model took over 60 seconds. Check storage and try again.',
  '本地模型准备超时，请检查设备存储空间后重试。':
      'Preparing the local model timed out. Check device storage and try again.',
  '本地模型复制不完整，请重试。': 'The local model copy is incomplete. Try again.',
  '当前设备未注册移动端分析模块。':
      'The mobile analysis module is not registered on this device.',
  '项目包缺少 project.json': 'The project package is missing project.json.',
  '当前平台不支持打开文件目录': 'Opening folders is not supported on this platform.',
  '配置草稿加载失败': 'Could not load the setup draft',
  '配置草稿保存失败': 'Could not save the setup draft',
  '确认后保存检测区域并开始分析；已有候选将被当前配置替换。':
      'Confirm to save detection regions and start analysis; existing candidates will be replaced.',
  '支持 MP4、MOV、M4V、AVI、MKV。原始视频不会被修改或上传。':
      'Supports MP4, MOV, M4V, AVI, and MKV. The source video is not modified or uploaded.',
  '篮网检测区': 'Net detection area',
  '当前编辑白色篮网区域：覆盖篮圈下方到网底，尽量不要包含篮板、球员或地面。':
      'Editing the white net region: cover the area below the rim down to the bottom of the net; avoid the backboard, players, and floor.',
  '当前编辑橙色投篮分析区域：覆盖来球轨迹、篮圈和篮网下方的落球范围。':
      'Editing the orange shot analysis region: cover the incoming ball path, rim, and the area below the net where the ball falls.',
  '恢复篮网区': 'Reset net region',
  '恢复投篮区': 'Reset shot region',
  '暂无法估算': 'Estimate unavailable',
  '重试加载': 'Retry loading',
  '显示全部': 'Show all',
  '全部候选': 'All candidates',
  '保留': 'Included',
  '排除': 'Excluded',
  '待审核': 'Pending review',
  '已确认': 'Confirmed',
  '已排除': 'Excluded',
  '低置信度': 'Low confidence',
  '保留片段': 'Included clips',
  '排除片段': 'Excluded clips',
  '当前候选被纳入审核列表的主要原因。':
      'The main reason this candidate was added to the review list.',
  '撤销上一次审核 (Cmd/Ctrl+Z)': 'Undo the previous review (Cmd/Ctrl+Z)',
  '调整片段范围': 'Adjust clip range',
  '筛选候选': 'Filter candidates',
  '候选预览': 'Candidate preview',
  '原视频': 'Original video',
  'ONNX Runtime 初始化失败': 'ONNX Runtime initialization failed',
  'Android 原生推理库无法加载':
      'The Android native inference library could not be loaded',
  'Rust Runtime 无法加载模型或 ONNX Runtime':
      'Rust Runtime could not load the model or ONNX Runtime',
  '视频解码不完整': 'Video decoding was incomplete',
  '已有分析任务正在运行': 'An analysis task is already running',
  '分析参数无效': 'Invalid analysis arguments',
  '视频片段参数无效': 'Invalid video clip arguments',
  '媒体路径无效': 'Invalid media path',
  '没有保存到相册的权限': 'Permission to save to the photo library was denied',
  '保存到相册失败': 'Could not save to the photo library',
  '导出失败': 'Export failed',
  '合并导出失败': 'Merged export failed',
  '关闭': 'Close',
  '最小化': 'Minimize',
  '最大化 / 还原': 'Maximize / restore',
  '取消': 'Cancel',
  '切换浅色主题': 'Switch to light theme',
  '切换深色主题': 'Switch to dark theme',
  '更多操作': 'More actions',
  '添加': 'Add',
  '保存': 'Save',
  '删除项目？': 'Delete project?',
  '删除项目': 'Delete project',
  '删除': 'Delete',
  '删除球员？': 'Delete player?',
  '删除“': 'Deleting “',
  '删除当前项目？': 'Delete the current project?',
  '当前项目': 'Current project',
  '当前项目没有视频': 'The current project has no video',
  '项目': 'Project',
  '导入': 'Import',
  '审核': 'Review',
  '分析': 'Analysis',
  '导出': 'Export',
  '重试导出': 'Retry export',
  '合并导出': 'Merge export',
  '分别导出': 'Export separately',
  '返回审核': 'Back to review',
  '导出范围': 'Export scope',
  '当前保留': 'Included',
  '播放/暂停': 'Play / pause',
  '播放位置': 'Position',
  '范围': 'Range',
  '前': 'before',
  '后': 'after',
  '播放': 'Play',
  '暂停': 'Pause',
  '后退': 'Rewind',
  '前进': 'Forward',
  '重播': 'Replay',
  '重播当前片段': 'Replay current clip',
  '秒': 'sec',
  '循环播放': 'Loop playback',
  '开启循环播放': 'Enable loop playback',
  '关闭循环播放': 'Disable loop playback',
  '批量设置片段时长': 'Set clip duration in bulk',
  '进球前': 'Before shot',
  '进球后': 'After shot',
  '覆盖手动调整过的片段': 'Overwrite manually adjusted clips',
  '关闭时会保留手动调整的范围': 'When off, keep manually adjusted ranges',
  '应用': 'Apply',
  '补漏候选': 'Add candidate',
  '补漏片段': 'Add clip',
  '已定位到原视频当前时间。调整起止时间后加入候选。':
      'The current source-video time is selected. Adjust the range and add it as a candidate.',
  '加入候选': 'Add candidate',
  '候选备注': 'Candidate note',
  '例如：补篮、擦框、镜头遮挡': 'e.g. put-back, rim hit, or camera obstruction',
  '重新分析当前视频？': 'Analyze the current video again?',
  '快速分析可能漏检，建议改用标准模式重新分析。当前候选会在新结果成功后替换，原始视频不会被删除。':
      'Fast analysis may miss clips. Standard mode is recommended; current candidates will be replaced only after the new result succeeds.',
  '重新分析会替换当前候选列表，但不会删除原始视频。':
      'Analyzing again replaces the current candidate list but does not delete the source video.',
  '用标准模式重新分析': 'Analyze again in standard mode',
  '重新分析': 'Analyze again',
  '用视频控制确认时间，再拖动两端确定要审核的片段。':
      'Use the video controls to confirm the moment, then drag both ends to set the clip.',
  '加入审核列表': 'Add to review list',
  '先用上方视频找到位置，再拖动滑杆两端微调片段起止。':
      'Find the moment in the video above, then drag both slider handles to fine-tune the clip.',
  '松手后继续播放': 'Resume after release',
  '松手后定位并暂停': 'Seek and pause after release',
  '候选片段': 'Candidate clips',
  '候选置信度': 'Candidate confidence',
  '轨迹评分': 'Trajectory score',
  '预测评分': 'Prediction score',
  '轨迹穿框': 'Trajectory crossing',
  '反弹判断': 'Rebound check',
  '收起候选列表': 'Collapse candidate list',
  '打开候选列表': 'Open candidate list',
  '关闭标注': 'Hide annotations',
  '打开标注': 'Show annotations',
  '退出横屏审核': 'Exit landscape review',
  '播放速度': 'Playback speed',
  '选择球员标签': 'Choose player tag',
  '不选': 'Exclude',
  '还没有候选片段': 'No candidate clips yet',
  '先完成视频分析，结果会自动出现在这里。':
      'Finish video analysis first; results will appear here automatically.',
  '分析没有找到候选，也可以手动补一个片段。':
      'Analysis found no candidates. You can add a clip manually.',
  '返回项目': 'Back to project',
  '候选判断依据': 'Candidate evidence',
  '综合置信度': 'Overall confidence',
  '轨迹分数': 'Trajectory score',
  '穿框分数': 'Crossing score',
  '篮网运动': 'Net motion',
  '轨迹点': 'Trajectory points',
  '算法结论': 'Algorithm verdict',
  '审核提示': 'Review hint',
  '颜色说明': 'Color legend',
  '绿色：确认穿框点': 'Green: confirmed crossing point',
  '橙色：篮球轨迹、当前位置或推定穿框点':
      'Orange: ball trajectory, current position, or estimated crossing point',
  '最终是否保留由你审核决定，算法结果只是候选建议。':
      'You decide whether to keep the clip; algorithm results are only suggestions.',
  '快捷键\nSpace  播放/暂停\nL  循环当前\nA  显示/关闭标注\n↑ / ↓  切换候选\n← / →  快退/快进 2 秒 · 加 Shift 每次 0.1 秒\nC / Enter  保留\nX / ` / Backspace  排除\n1–9、Q–P  设置球员标签 · 0  清除\nCmd/Ctrl+Z  撤销':
      'Shortcuts\nSpace  Play/pause\nL  Loop current\nA  Show/hide annotations\n↑ / ↓  Switch candidates\n← / →  Rewind/forward 2 sec · with Shift 0.1 sec\nC / Enter  Include\nX / ` / Backspace  Exclude\n1–9, Q–P  Set player tag · 0  Clear\nCmd/Ctrl+Z  Undo',
  '未命名项目': 'Untitled project',
  '新建项目': 'New project',
  '原始视频不可用，无法预览片段范围':
      'The source video is unavailable, so the clip range cannot be previewed.',
  '预测篮球继续下落后的落点是否接近篮筐中心，不是进球概率。':
      'Whether the ball would land near the hoop center if it continued downward; this is not a make probability.',
  '补漏片段没有模型预测评分。':
      'Manually added clips have no model prediction score.',
  '复核': 'Review',
  '系统说明': 'System note',
  '写备注': 'Add note',
  '编辑备注': 'Edit note',
  '球员标签': 'Player tags',
  '球员：': 'Player: ',
  '备注': 'Note',
  '记录这个候选的情况': 'Record details about this candidate',
  '保存备注': 'Save note',
  '新建球员标签': 'Create player tag',
  '例如 #10 Kobe': 'e.g. #10 Kobe',
  '还没有球员标签。': 'No player tags yet.',
  '选择球员': 'Choose player',
  '完成管理': 'Finish managing',
  '管理': 'Manage',
  '清除标签': 'Clear tag',
  '应用标签': 'Apply tag',
  '疑似进球': 'Likely made shot',
  '疑似未进': 'Likely missed shot',
  '需要审核': 'Needs review',
  '篮网运动较弱': 'Weak net motion',
  '可能反弹': 'Possible rebound',
  '可能横向离开': 'May have left sideways',
  '投篮轨迹不足': 'Insufficient shot trajectory',
  '可能擦框偏出': 'May have hit the rim and missed',
  '证据不足，建议人工确认': 'Insufficient evidence; verify manually',
  '分享': 'Share',
  '保存到相册': 'Save to photos',
  '最近导出': 'Recent exports',
  '还没有导出记录': 'No export history yet',
  '完成一次导出后，历史记录会出现在这里。':
      'Export something once and its history will appear here.',
  '本次输出使用启动导出时的片段列表，之后的审核修改用于下一次导出。':
      'This export uses the clip list captured when it started. Later review changes apply to the next export.',
  '导出任务在后台运行，返回审核后仍可继续修改候选。':
      'The export is running in the background. You can continue editing candidates in Review.',
  '导出会包含所有当前保留的候选；已排除片段不会进入输出。':
      'Exports include all currently included candidates; excluded clips are not output.',
  '视频': 'Video',
  '打开目录': 'Open folder',
  '无法打开目录': 'Could not open folder',
  '知道了': 'Got it',
  '选择视频': 'Choose video',
  '继续选择': 'Choose another',
  '更换当前视频？': 'Replace the current video?',
  '更换视频会创建一个新的分析项目，当前项目和审核记录会保留。':
      'Replacing the video creates a new analysis project; the current project and review records are kept.',
  '这个视频可能需要较长时间': 'This video may take a while',
  '先取消': 'Cancel',
  '继续导入': 'Continue import',
  '应用新配置？': 'Apply the new setup?',
  '放弃草稿': 'Discard draft',
  '继续配置': 'Continue setup',
  '选择原始视频': 'Choose source video',
  '应用并重新分析': 'Apply and analyze again',
  '检测到上次未完成的配置。': 'An unfinished setup was found.',
  '视频已准备好': 'Video is ready',
  '视频体量偏大，处理时间会比普通视频更长': 'This video is large and will take longer than usual.',
  '视频体量较大，后续处理可能需要较长时间':
      'This video is large and later processing may take a while.',
  '默认分析全片。拖动范围手柄排除热身、暂停或比赛结束部分，修改会自动保存在当前草稿。':
      'The full video is analyzed by default. Drag the range handles to exclude warm-up, pauses, or the end; changes save automatically.',
  '系统会先自动识别篮筐。橙色区域用于球轨迹，白色区域只覆盖篮网摆动范围；拖动或缩放后会自动保存到草稿。':
      'The hoop is detected automatically. The orange region tracks the ball and the white region covers net motion; changes save to the draft automatically.',
  '候选片段长度': 'Candidate clip length',
  '标准分析': 'Standard analysis',
  '快速分析': 'Fast analysis',
  '快速分析使用低规格代理，可能漏检少量片段。':
      'Fast analysis uses a lower-resolution proxy and may miss some clips.',
  '确认配置': 'Confirm setup',
  '确认并分析': 'Confirm and analyze',
  '使用全片': 'Use full video',
  '播放进度': 'Playback progress',
  '标记画面': 'Mark frame',
  '缩小': 'Zoom out',
  '放大': 'Zoom in',
  '适应画面': 'Fit to view',
  '横屏全屏': 'Landscape full screen',
  '返回上一步': 'Back',
  '从分析范围起点重播': 'Replay from analysis start',
  '缩小画面': 'Zoom out',
  '放大画面': 'Zoom in',
  '复位': 'Reset view',
  '重置当前': 'Reset current',
  '完成': 'Done',
  '设置检测区域': 'Set detection regions',
  '覆盖投篮发生区域': 'Cover the shot area',
  '覆盖白色篮网区域': 'Cover the white net area',
  '投篮分析区': 'Shot analysis area',
  '篮网区域': 'Net area',
  '拖动重画中': 'Redrawing',
  '重新画框': 'Redraw region',
  '拖动出一个新矩形来重新设置当前区域。': 'Drag a new rectangle to replace the current region.',
  '拖动框角调整大小，拖动画面移动区域；双指捏合放大画面。':
      'Drag corners to resize, drag the canvas to move, and pinch to zoom.',
  '分析质量': 'Analysis quality',
  '分析范围': 'Analysis range',
  '标准': 'Standard',
  '高质量': 'High quality',
  '640 输入 / 10fps，候选窗口精筛': '640 input / 10fps, refined candidate scan',
  '640 输入 / 10fps，更高质量代理': '640 input / 10fps, higher-quality proxy',
  '片段时长': 'Clip duration',
  '重新生成预览': 'Regenerate preview',
  '生成预览': 'Generate preview',
  '请先选择视频': 'Choose a video first',
  '预览帧不可用': 'Preview frame unavailable',
  '正在准备视频预览': 'Preparing video preview',
  '选择输出目录': 'Choose output folder',
  '处理方式': 'Processing',
  '输出编码': 'Output codec',
  '合计时长': 'Total duration',
  '当前筛选': 'Current filter',
  '分析结果默认保留，导出时只排除你打叉的片段。':
      'Analysis results are included by default. Export only excludes clips you reject.',
  '视频仍在分析，分析完成后才能导出新的候选结果。':
      'The video is still being analyzed. New candidates can be exported when analysis finishes.',
  '当前结果来自快速分析，可能漏检；如需更完整结果，建议先用标准模式重新分析。':
      'This result came from fast analysis and may miss clips. Use standard analysis for a more complete result.',
  '上次导出已中断，可以从原设置重新导出。':
      'The previous export was interrupted. You can export again with the same settings.',
  '文件大小未知': 'Unknown file size',
  '分辨率未知': 'Unknown resolution',
  '确认配置并开始分析': 'Confirm setup and start analysis',
  '开始': 'Start',
  '结束': 'End',
  '时:分:秒': 'hh:mm:ss',
  '投篮分析区太小': 'Shot analysis area is too small',
  '检测区域无法保存': 'Detection region could not be saved',
  '检测区域超出画面': 'Detection region is outside the frame',
  '导入未确认，项目已保留；稍后打开检查，请勿重复导入':
      'Import not confirmed. The project is saved; reopen it later to check. Do not import it again.',
  '项目可能已创建；稍后打开检查，请勿重复导入':
      'The project may have been created. Reopen it later to check; do not import it again.',
  '无法记住项目目录': 'Could not remember the project folder',
  '项目正在读取，请稍后重试': 'The project is being read. Please try again shortly.',
  '请求队列已满，请稍后重试': 'The request queue is full. Please try again shortly.',
  '导入失败，项目已保留': 'Import failed. The project was kept',
  '校验原视频': 'Checking source video',
  '复核原视频': 'Rechecking source video',
  '导出启动结果尚未确认，请重新连接后检查现有任务。': 'Export start is unconfirmed. Reconnect and check existing tasks.',
  '导出任务保护状态读取失败，已忽略': 'Could not read export protection status; it was ignored.',
  '上一次导出启动结果未确认，请先查看导出任务': 'The previous export start is unconfirmed. Check export tasks first.',
  '未找到可确认的导出任务，请检查后再决定是否允许重新导出。': 'No matching export task was found. Check before allowing another export.',
  '查看导出任务': 'Check export tasks',
  '导出任务状态无法保存，请下次打开项目时重新检查。': 'Could not save export status. Check again when reopening the project.',
  '无法保存导出任务状态，未开始导出。': 'Could not save export status. The export was not started.',
  '允许再次导出？': 'Allow another export?',
  '请先检查导出任务和已生成的文件。上一次导出可能仍在运行或已经完成。': 'Check export tasks and generated files first. The previous export may still be running or may have finished.',
  '已检查，允许再次导出': 'Checked, allow another export',
  '原项目没有视频指纹，无法比对原视频内容。': 'This project has no video fingerprint; the source content cannot be compared.',
  '项目正在导出，请等待完成或取消': 'The project is exporting. Wait for it to finish or cancel it.',
  '导入未确认，项目已保留': 'Import was not confirmed. The project was kept',
  '项目可能已创建': 'The project may have been created',
  '复制项目路径': 'Copy project path',
  '导入失败，项目已保留；稍后可从最近项目打开。':
      'Import failed. The project is saved; you can open it later from recent projects.',
  '无法记住项目目录，请记下项目保存位置。':
      'Could not remember the project folder. Please note where the project was saved.',
  '处理时间较长': 'Processing may take a while',
  '请从左上向右下拖出一个有效矩形，再松开鼠标。':
      'Drag a valid rectangle from top left to bottom right, then release the mouse.',
  '请把四个手柄拖回预览画面内。': 'Move all four handles back inside the preview.',
  '请扩大橙色区域，覆盖篮筐、篮网和球落下的位置。':
      'Expand the orange region to cover the hoop, net, and the ball landing area.',
  '请稍候查看任务状态，原始视频不会被修改。':
      'Check the task status in a moment. The source video will not be modified.',
  '暂无球员': 'No players yet',
  '新建球员': 'New player',
  '球员分组': 'Player groups',
  '这场比赛的视频': 'Videos of this game',
  '每段都设置好篮筐后，点「分析全部」会按顺序逐段分析，分析完的段可以先去审核。':
      'Once every part has its hoop set, “Analyse all” runs the parts one after another. You can review a part as soon as it finishes.',
  '添加视频': 'Add videos',
  '分析设置': 'Analysis settings',
  '队列已暂停': 'Queue paused',
  '还有': '',
  '段待分析': 'parts left',
  '正在排队分析': 'Analysing in order',
  '导出排在这段之后': 'Export runs after this part',
  '继续排队': 'Resume queue',
  '暂停队列': 'Pause queue',
  '暂停后，正在分析的这段会继续完成，之后不再开始新的一段。':
      'Pausing lets the current part finish and then stops before the next one.',
  '需要设置篮筐': 'Hoop not set',
  '请确认自动识别的篮筐': 'Confirm detected hoop',
  '确认篮筐': 'Confirm hoop',
  '沿用上一段的篮筐': 'Hoop from previous part',
  '自动识别篮筐': 'Hoop detected',
  '篮筐已设置': 'Hoop set',
  '分析中': 'Analysing',
  '排队中': 'Queued',
  '个候选': 'candidates',
  '已取消': 'Cancelled',
  '未分析': 'Not analysed',
  '原视频已移动': 'Source video moved',
  '移出队列': 'Remove from queue',
  '上移': 'Move up',
  '下移': 'Move down',
  '设置篮筐': 'Set hoop',
  '调整': 'Adjust',
  '分析全部': 'Analyse all',
  '保存这一段的设置': 'Save this part',
  '支持 MP4、MOV、M4V、AVI、MKV。同一场比赛的多段视频可以一起选，会建成一个项目。原始视频不会被修改或上传。':
      'MP4, MOV, M4V, AVI and MKV are supported. Pick several parts of one game together to make one project. Source videos are never modified or uploaded.',
  '添加同一场的其他视频': 'Add more parts of this game',
  '正在添加视频…': 'Adding videos…',
  '正在识别第 1 段的篮筐…': 'Detecting the hoop in part 1…',
  '正在调整视频顺序…': 'Reordering videos…',
  '没有需要分析的视频段': 'No parts need analysis',
  '全部视频段分析完成': 'All parts analysed',
  '导出会在当前这段分析完成后开始，之后继续排队':
      'The export starts after the current part, then the queue continues',
  '视频段': 'Parts',
  '按视频段筛选': 'Filter by part',
  '运行日志': 'Logs',
  '打开日志目录': 'Open log folder',
  '存为分组': 'Save as group',
  '例如：周六球队': 'e.g. Saturday team',
  '还没有分组。把当前项目的球员存为分组后，其他项目可以一键导入。':
      'No groups yet. Save this project\'s players as a group to import them into other projects in one tap.',
  '把当前球员存为分组': 'Save current players as a group',
  '默认': 'Default',
  '分组已变更，请重新选择': 'The group changed. Choose it again.',
  '球员顺序影响名单显示顺序': 'Player order determines roster order.',
  '确认移除球员？': 'Remove this player?',
  '管理分组': 'Manage groups',
  '确认删除分组？': 'Delete this group?',
  '已有同名分组，是否替换？': 'Replace the existing group?',
  '替换': 'Replace',
  '分组操作未完成': 'Group operation was not completed',
  '分组数据异常，无法修改': 'Player group data is invalid and cannot be changed.',
  '这个分组还没有球员': 'This group has no players yet',
  '球员名单': 'Player roster',
  '正在读取球员分组…': 'Loading player groups…',
  '还没有球员分组，可以在审核页把球员存为分组。': 'No player groups yet. Save players as a group on the review page.',
  '选择球员分组': 'Choose a player group',
  '不使用': 'None',
  '设为默认': 'Set as default',
  '取消默认': 'Clear default',
  '项目已有球员。选择分组可追加名单，不会删除或调整现有球员。': 'This project already has players. Choose a group to add players without removing or reordering existing players.',
  '只勾选本次出场的球员，不会修改分组。': 'Select the players attending this time. The saved group stays unchanged.',
  '分组名不能为空': 'Enter a group name.',
  '分组名已存在，请使用其他名称': 'This group name already exists. Choose another name.',
  '球员名不能为空': 'Enter a player name.',
  '分组内的球员不能重名': 'Player names must be unique within the group.',
  '编辑球员分组': 'Edit player group',
  '分组名称': 'Group name',
  '球员姓名': 'Player name',
  '拖动调整顺序，顺序对应球员快捷键（1–9、Q–P）。': 'Drag to reorder. Player order determines keyboard shortcuts (1–9, Q–P).',
  '拖动调整顺序': 'Drag to reorder',
  '移除球员': 'Remove player',
  '还没有球员，请添加。': 'No players yet. Add a player.',
  '球员分组已不存在，请重新选择': 'This player group no longer exists. Choose another group.',
  '球员名单未完整导入': 'The player roster was not fully imported',
  '请重试导入后再开始分析。': 'Retry importing the roster before starting analysis.',
  '球员已导入': 'Players imported',
  '正在导入球员…': 'Importing players…',
  '标注': 'Annotations',
  '标注会显示轨迹与判定点 · 按 A 可开关':
      'Annotations show the trajectory and decision points · press A to toggle',
  '暂停（Space）': 'Pause (Space)',
  '播放（Space）': 'Play (Space)',
  '关闭标注（A）': 'Hide annotations (A)',
  '显示标注（A）': 'Show annotations (A)',
  '循环当前片段 (L)': 'Loop current clip (L)',
  '关闭循环播放 (L)': 'Disable loop playback (L)',
  '粗扫通过': 'Passed coarse scan',
  '未计算': 'Not calculated',
  '通过': 'Passed',
  '推定穿框': 'Inferred crossing',
  '未通过': 'Not passed',
  '有支持': 'Supported',
  '信号较弱': 'Weak signal',
  '明显': 'Strong',
  '有运动': 'Motion detected',
  '检测到': 'Detected',
  '未发现': 'Not found',
  '可能传球': 'Possible pass',
  '可能未形成投篮': 'Possible no shot',
  '可能擦框/弹出': 'Possible rim-out',
  '篮网信号较弱': 'Weak net signal',
  '证据不确定': 'Uncertain evidence',
  '手动片段': 'Manual clip',
  '轨迹不足': 'Insufficient trajectory',
  '高': 'High',
  '中': 'Medium',
  '低': 'Low',
  '开始前预计耗时：': 'Estimated time before analysis: ',
  '\n实际耗时会受视频编码、磁盘和设备负载影响。':
      '\nActual time depends on video encoding, disk, and device load.',
  '选择原始视频后即可框选篮筐区域。':
      'Choose a source video to mark the hoop region.',
  '视频元数据已读取，可以重新生成预览后继续框选。':
      'Video metadata is ready. Regenerate the preview to continue marking the region.',
  '预览准备好后即可拖拽框选篮筐区域。':
      'Drag to mark the hoop region once the preview is ready.',
  '拖动时间轴两端即可调整。视频会跳到正在拖动的一端；原视频不会被修改。':
      'Drag either end of the timeline to adjust. The video seeks to the handle being moved; the source video is not modified.',
  '分析完成后会在这里预览候选片段，点击播放开始':
      'Candidate clips will appear here after analysis. Click play to start.',
  '综合轨迹穿框、篮网运动和反弹等信号得出，只用于排序和辅助审核。':
      'Combines trajectory crossing, net motion, and rebound signals for sorting and review assistance only.',
  '判断篮球轨迹是否从篮筐上方进入，并在篮筐横向范围内向下穿过。':
      'Checks whether the ball enters from above and travels downward through the hoop width.',
  '检测白色篮网区域在球经过后的运动强度；光线、球员遮挡会影响该信号。':
      'Measures motion in the white net area after the ball passes; lighting and player occlusion can affect it.',
  '检测篮球撞框后向上或向外回弹；出现反弹通常降低进球可能性。':
      'Checks whether the ball rebounds upward or outward after hitting the rim; a rebound usually lowers the chance of a make.',
  '从原视频当前时间补漏候选':
      'Add a missing candidate at the current source-video time',
  '未找到可用的邮件客户端，请手动联系反馈邮箱。':
      'No mail client is available. Contact the feedback email manually.',
  '篮球高光视频助手': 'Basketball Highlight Editor',
  '本地处理，原始视频不会自动上传':
      'Processed locally; the source video is not uploaded automatically.',
  '关于 BHE': 'About BHE',
  '最近项目': 'Recent projects',
  '打开项目': 'Open project',
  '正在准备视频…': 'Preparing video…',
  '视频已加载，已优先尝试自动识别篮筐区域':
      'Video loaded; automatic hoop detection was attempted first.',
  '分析已开始，完成后会显示候选片段':
      'Analysis started. Candidate clips will appear when it finishes.',
  '导出完成': 'Export complete',
  '视频加载失败': 'Video failed to load',
  '代理': 'Proxy',
  '粗扫': 'Coarse scan',
  '候选': 'Candidates',
  '精筛': 'Refinement',
  '封面': 'Covers',
  '落库': 'Save results',
  '篮筐逐帧复核': 'Frame-by-frame rim check',
  '自动排除': 'Auto-excluded',
  '篮筐复核': 'Rim check',
  '未确认': 'Unsure',
  '按篮筐复核结果筛选': 'Filter by rim check',
  '未审核': 'Unreviewed',
  '没有符合筛选的候选': 'No candidates match the filters',
  '清除筛选': 'Clear filters',
  '球员': 'Player',
  '已标注': 'Tagged',
  '未标注': 'Untagged',
  '按球员筛选': 'Filter by player',
  '播放片段': 'Play clip',
  '预览结尾': 'Preview ending',
  '设为开始': 'Set start here',
  '设为结束': 'Set end here',
  '开头 −2 秒': 'Start −2 s',
  '结尾 +2 秒': 'End +2 s',
  '前后各 +2 秒': '+2 s on both ends',
  '进球时刻': 'Shot moment',
  '原范围': 'Original range',
  '片段时间轴': 'Clip timeline',
  '拖动两端调整范围，点时间轴跳到该位置。': 'Drag either end to adjust the range; tap the timeline to jump there.',
  '按原视频逐帧放大篮筐区域，确认球从篮筐上方进入、被篮网遮挡并从网底落下。只有看清球没进的候选会自动排除；没看清的保留并标为未确认，都可以随时修改。':
      'Zooms into the rim on every source frame to confirm the ball enters from above, is hidden by the net and drops out of the bottom. Only candidates clearly seen missing are auto-excluded; unclear ones stay and are marked unsure. You can change any of them.',
  '通过：球穿过篮网落下': 'Passed: the ball dropped through the net',
  '未通过：没有看到球穿过篮筐': 'Failed: no ball was seen crossing the rim',
  '未通过：球不是从篮筐上方落下': 'Failed: the ball did not come down from above the rim',
  '未通过：球偏离篮筐口': 'Failed: the ball missed the rim opening',
  '未通过：没有看到球从网底落下': 'Failed: the ball was not seen leaving the bottom of the net',
  '未通过：球从篮网侧面出来': 'Failed: the ball left from the side of the net',
  '未通过：球在篮筐附近弹起': 'Failed: the ball bounced up near the rim',
  '未通过：球从篮筐前方掠过，没有进网': 'Failed: the ball passed in front of the rim, not through the net',
  '未通过：球落下时篮网没有动': 'Failed: the net did not move when the ball came down',
  '未确认：没看清球是否穿过篮筐，请人工确认': 'Unsure: the ball crossing the rim was not seen clearly, please review',
  '未确认：没看清球是否从篮筐上方落下，请人工确认': 'Unsure: the ball coming down from above the rim was not seen clearly, please review',
  '未确认：没看清球是否从网底落下，请人工确认': 'Unsure: the ball leaving the bottom of the net was not seen clearly, please review',
  '未确认：球像是偏离篮筐口，但轨迹不像一颗下落的球，请人工确认': 'Unsure: the ball seems to miss the rim opening, but the track does not look like a falling ball, please review',
  '未确认：球全程可见，这个视频的篮网不一定挡得住球，请人工确认': 'Unsure: the ball stayed visible, but the net in this video may not hide it, please review',
  '未确认：请人工确认': 'Unsure: please review',
  '未复核：篮筐在画面中太小，请人工确认': 'Not checked: the rim is too small in the frame, please review manually',
  '未复核：请人工确认': 'Not checked: please review manually',
  'Engine 返回未知错误': 'Engine returned an unknown error',
  'Engine 已关闭': 'Engine is closed',
  '视频预览加载失败：': 'Video preview failed: ',
  '自动切换标记画面失败：': 'Could not switch the marked frame: ',
  '任务状态加载失败：': 'Could not load task status: ',
  '导出记录加载失败：': 'Could not load export history: ',
  '关闭项目失败：': 'Could not close the project: ',
  '无法向 Engine 发送请求：': 'Could not send the request to Engine: ',
  '请求处理超时：': 'Request timed out: ',
  '当前操作尚未结束，暂时无法退出：':
      'The current operation has not finished, so the app cannot exit yet: ',
  '未找到 Python 运行时。请设置 BHE_PYTHON，或把 Python 放入应用运行时目录。':
      'Python runtime not found. Set BHE_PYTHON or place Python in the app runtime directory.',
  '未找到本地 Engine 运行目录。开发环境请从项目根目录启动，正式版本请先完成运行时打包。':
      'Local Engine runtime directory not found. Start from the project root in development, or package the runtime for a release build.',
  '原始视频已移动，请重新定位后再开始分析或导出。':
      'The source video was moved. Relink it before analyzing or exporting.',
  '篮筐区域已保存': 'Hoop region saved',
  '分析范围已保存': 'Analysis range saved',
  '已重新开始分析': 'Analysis restarted',
  '分析完成，候选片段已准备好': 'Analysis complete; candidate clips are ready',
  '正在取消导出…': 'Cancelling export…',
  '正在取消分析…': 'Cancelling analysis…',
  '正在启动分析…': 'Starting analysis…',
  '正在保存配置…': 'Saving setup…',
  '正在生成视频预览…': 'Generating video preview…',
  '篮筐可见度较高，如被遮挡可调整画面时间。':
      'The hoop is clearly visible. Adjust the frame time if it is obstructed.',
  '正在切换标记画面…': 'Switching the marked frame…',
  '正在自动识别篮筐区域…': 'Detecting the hoop region automatically…',
  '实际耗时会受视频编码、磁盘和设备负载影响。':
      'Actual time depends on video encoding, disk, and device load.',
  '无音频': 'No audio',
  '已完成': 'complete',
  '未完成': 'incomplete',
  '当前已有': 'There are currently',
  '当前区域': 'Current region',
  '引擎': 'Engine',
  '正在识别篮筐区域…': 'Detecting the hoop region…',
  '标记画面切换失败：': 'Could not switch the marked frame: ',
  '视频已重新定位': 'Video relinked',
  '视频内容与原项目不一致，旧候选和 ROI 已清空，请重新设置后分析':
      'The video content does not match the project record. Previous candidates and ROI were cleared; set them again before analyzing.',
  '视频已重新定位，项目数据和审核记录已保留':
      'Video relinked; project data and review records were kept.',
  '项目已删除（原始视频未删除）':
      'Project deleted; the source video was not deleted',
  '请先设置投篮分析区': 'Set the shot analysis region first',
  '视频元数据尚未准备好': 'Video metadata is not ready yet',
  '视频分辨率无效': 'The video resolution is invalid',
  '分析任务仍在运行，已恢复状态监听':
      'An analysis task is still running; status monitoring was restored',
  '已保留片段': 'Clip included',
  '已暂缓审核': 'Review deferred',
  '已标记二次复核': 'Marked for a second review',
  '已恢复待审核': 'Restored to pending review',
  '已排除候选': 'Candidate excluded',
  '备注已保存': 'Note saved',
  '已撤销上一次审核': 'The previous review was undone',
  '片段范围已更新': 'Clip range updated',
  '已更新片段时长': 'Clip duration updated',
  '补漏片段已加入候选': 'The missing clip was added to candidates',
  '球员已添加': 'Player added',
  '正在添加球员…': 'Adding player…',
  '正在保存球员标签…': 'Saving player tags…',
  '正在删除球员…': 'Deleting player…',
  '正在保存修改并关闭项目…': 'Saving changes and closing the project…',
  '球员已删除': 'Player deleted',
  '选择输出位置失败：': 'Could not choose an output location: ',
  '正在准备输出位置…': 'Preparing output location…',
  '跳过': 'Skip',
  '选中一个候选就会播放对应的片段，每个候选前后会多留一点画面。': 'Pick a candidate to play that clip; each one includes a little footage before and after.',
  '每一行是系统认为可能进球的一段。逐个看一遍，是进球就保留，不是就排除。': 'Each row is a moment the app thinks may be a made shot. Go through them: keep the goals, exclude the rest.',
  '常用快捷键': 'Common shortcuts',
  '完整列表：右上角「更多」→「快捷键一览」': 'Full list: top-right "More" → "Keyboard shortcuts"',
  '给片段打球员标签': 'Tag a clip with a player',
  '点这里选球员；还没有球员就新建，也可以从「球员分组」一键导入。打过标签，导出时可以每个球员各出一个视频。': 'Click here to pick a player; create one if there are none, or import a saved player group. Tagged clips can be exported as one video per player.',
  '片段前后不对？调范围': 'Clip starts or ends in the wrong place? Adjust the range',
  '点这里打开范围编辑：拖动两端、拖到边缘继续延长，或播放到合适位置按 I 设为开始、O 设为结束。原视频不会被修改。': 'Open the range editor: drag either end (drag to the edge to extend), or play to the right spot and press I for start, O for end. Your original video is never changed.',
  '候选预览 / 原视频': 'Candidate preview / Original video',
  '切到「原视频」可以看整段录像、补上系统没找到的进球。': 'Switch to "Original" to watch the whole recording and add goals the app missed.',
  '播放 / 暂停': 'Play / Pause',
  '后退 2 秒': 'Back 2 s',
  '加 Shift 后退 0.1 秒': 'Hold Shift to go back 0.1 s',
  '前进 2 秒': 'Forward 2 s',
  '加 Shift 前进 0.1 秒': 'Hold Shift to go forward 0.1 s',
  '保留这个候选': 'Keep this candidate',
  '排除这个候选': 'Exclude this candidate',
  '撤销上一步审核': 'Undo last review action',
  '循环播放当前片段': 'Loop the current clip',
  '显示 / 隐藏识别标注': 'Show / hide detection overlay',
  '给片段选第 N 个球员': 'Tag with the Nth player',
  '清除球员标签': 'Clear the player tag',
  '快捷键一览': 'Keyboard shortcuts',
  '审核页': 'Review page',
  '调整范围窗口': 'Range editor window',
  '把当前位置设为开始': 'Set current position as start',
  '把当前位置设为结束': 'Set current position as end',
  '前后 1 秒': '1 s back / forward',
  '按球员标签各出一个视频': 'One video per player tag',
  '给候选打过球员标签后，这里会多出「每个标签各合成一个视频」：每个标签一个 MP4，文件名就是标签名。': 'Once candidates are tagged with players, "One video per tag" appears here: one MP4 per tag, named after the tag.',
  '导入分四步': 'Import in four steps',
  '选视频 → 定分析范围 → 框出篮筐 → 开始分析。上面的步骤条可以点回已经完成的步骤，设置会自动保存为草稿。': 'Pick a video → set the analysis range → mark the hoop → start analysis. Click a finished step above to go back; settings are saved as a draft automatically.',
  '先选原始视频': 'Pick the original video first',
  '支持 MP4、MOV、M4V、AVI、MKV。同一场的多段视频可以一起选，会建成一个项目。原视频不会被修改或上传。': 'MP4, MOV, M4V, AVI and MKV are supported. Pick several videos from the same game together to make one project. Your original video is never changed or uploaded.',
  '只分析需要的一段': 'Analyze only the part you need',
  '拖动时间轴两端，选出要分析的范围，比如跳过赛前热身；不确定就保持整段。范围越短，分析越快。': 'Drag both ends of the timeline to choose the range, e.g. skip the warm-up; keep the whole video if unsure. A shorter range analyzes faster.',
  '框出篮筐': 'Mark the hoop',
  '系统会先自动识别篮筐。不准的话在画面上拖动、缩放；篮筐被挡住时，先换一个画面时间再框。': 'The app detects the hoop automatically. If it is off, drag or resize on the picture; if the hoop is blocked, change the frame time first.',
  '橙色和白色两个区域': 'Two areas: orange and white',
  '橙色区域覆盖来球轨迹、篮圈和落球范围，用来跟踪球；白色区域只盖篮网摆动范围。点这两个按钮切换要编辑的区域，改动自动保存。': "The orange area covers the ball's path, the rim and where the ball lands; the white area covers only the net's swing. Use these two buttons to switch which one you edit; changes save automatically.",
  '每个进球留多长': 'How long is each goal clip',
  '设置进球前、后各保留几秒。后面审核时，每个片段还能单独调整。': 'Set how many seconds to keep before and after each goal. You can still adjust each clip during review.',
  '标准还是快速': 'Standard or fast',
  '标准分析更完整、漏检少，推荐；快速分析更快，但可能漏掉少量片段。': 'Standard analysis is more thorough and misses less (recommended); fast analysis is quicker but may miss a few clips.',
  '开始分析': 'Start analysis',
  '点右下角的按钮开始（多段视频先保存这一段的设置，再在列表里「分析全部」）。分析在后台进行，结束后到「审核」页逐个确认候选。': "Click the button at the bottom right to start (with several videos, save this one's settings, then \"Analyze all\" in the list). Analysis runs in the background; when done, check candidates one by one on the Review page.",
  '正确：橙色框盖住来球轨迹、篮圈和网下落球范围，白色虚线框只盖篮网': "Right: the orange box covers the ball's path, the rim and where the ball lands; the white dashed box covers only the net",
  '太大：别把整块篮板、球员和地面框进去': "Too big: don't include the whole backboard, players or floor",
  '太小：只框篮圈，球一靠近或落下就出框': "Too small: a box on the rim alone loses the ball as soon as it comes near or drops",
  '框选示例': "Hoop marking examples",
  '看示例': "See examples",
  '橙色区域用来跟踪球：从球进入篮圈上方，到落出篮网下方。白色区域只盖篮网摆动范围，用来判断球有没有穿网。系统会先自动识别，不准再拖动或缩放。': "The orange area tracks the ball from above the rim to below the net. The white area covers only the net's swing and is used to tell whether the ball went through. The app detects the hoop first; drag or resize only if it is off.",
  '全部 / 保留 / 排除': "All / Kept / Excluded",
  '「全部」是系统找到的所有候选；「保留」是还没被排除的（包括你点了保留的和还没审核的）；「排除」是你打了叉的。\n推荐：看完一遍后点「保留」再过一遍，这里的就是最终会导出的；还可以在「保留」里接着按球员标签、篮筐检测结果筛选，挑出要重点检查的。': "\"All\" is every candidate the app found; \"Kept\" is everything not excluded (candidates you kept plus ones you have not reviewed yet); \"Excluded\" is what you crossed out.\nTip: after one pass, open \"Kept\" and review it again - that is exactly what gets exported. Inside \"Kept\" you can keep filtering by player tag or rim check result to focus your checks.",
  '想把所有片段统一加长或缩短，点这个按钮，设置每个进球「前」「后」各留几秒。只作用于当前列表里的候选（会随上面的筛选变化），默认不覆盖你手动调整过的片段。': "To lengthen or shorten every clip at once, click this and set how many seconds to keep before and after each goal. It applies only to the candidates in the current list (it follows the filters above) and by default does not overwrite clips you adjusted by hand.",
  '补漏：系统漏掉的进球': "Add missed goals",
  '先切到「原视频」，播放到漏掉的进球附近，再点「补漏片段」：会以当前位置作为进球时刻新建一个候选，在弹出的窗口里用 I / O 或拖动定好开始和结束，点「加入候选」即可。': "Switch to \"Original\", play to near the missed goal, then click \"Add missed clip\": a new candidate is created with the current position as the goal moment. In the window, set start and end with I / O or by dragging, then click \"Add to candidates\".",
  '快捷键': "Shortcuts",
  '分析队列已结束，有视频段没有分析成功，请在列表里查看': 'The analysis queue has finished, but some parts did not succeed - check the list',
  '本页新手引导': 'Guide for this page',
  '重置新手引导': 'Reset onboarding guide',
  '已重置，下次进入审核页和导出页会再次显示新手引导': 'Reset. The guide will show again next time you open Review and Export',
  '这里看视频': 'Watch the clip here',
  '这里是找到的候选': 'Candidates found for you',
  '先选输出方式': 'Choose how to export',
  '合并成一个视频，或每个片段单独导出；有球员标签时还能按标签各出一个。': 'Merge into one video, or export each clip separately; with player tags you can also get one video per tag.',
  '点这里导出': 'Export from here',
  '接着选保存位置，已排除的片段不会进入输出。导出在后台进行，期间可以回审核继续看；原视频不会被修改。': 'Next you pick where to save. Excluded clips are left out. Export runs in the background, so you can go back to Review; your original video is never changed.',
  '视频画面准备较慢，已直接打开选择窗口': 'The video view was slow to get ready; opening the picker now',
  '导出任务未返回 id': 'The export task did not return an id',
  '检查视频输入': 'Check video input',
  '生成预览视频': 'Generate preview video',
  '快速扫描候选': 'Scan for candidates',
  '精细分析候选': 'Refine candidates',
  '整理审核片段': 'Prepare review clips',
  '准备候选封面': 'Prepare candidate covers',
  '准备导出': 'Prepare export',
  '生成片段': 'Generate clips',
  '合并片段': 'Merge clips',
  '保存导出记录': 'Save export history',
  '正在导出': 'Exporting',
  '上一步': 'Back',
  '下一步': 'Next',
  '应用到': 'Apply to',
  '全部球员': 'All players',
  '关于': 'About',
  '即将开放': 'Coming soon',
  '收缩侧栏': 'Collapse sidebar',
  '展开侧栏': 'Expand sidebar',
  '关闭当前项目': 'Close current project',
  '关闭当前项目？': 'Close current project?',
  '关闭项目会先取消当前任务，项目数据和原始视频不会被删除。':
      'The current task will be cancelled first. Project data and the source video will not be deleted.',
  '项目数据和原始视频会保留，下次可以从项目列表重新打开。':
      'Project data and the source video will be kept and can be reopened from the project list.',
  '取消任务并关闭': 'Cancel task and close',
  '退出软件': 'Exit',
  '取消任务并退出': 'Cancel task and exit',
  '确认关闭软件吗？本地项目数据不会被删除。':
      'Close the app? Local project data will not be deleted.',
  '任务仍在进行': 'Task in progress',
  '当前任务还在进行，退出前需要先取消任务。':
      'A task is still running and must be cancelled before exiting.',
  '返回': 'Back',
  'Engine 就绪': 'Engine ready',
  'Engine 未启动': 'Engine not started',
  '等待 Engine': 'Waiting for Engine',
  'Engine 错误': 'Engine error',
  '候选片段加载失败：': 'Could not load candidate clips: ',
  '开始记录审核耗时失败：': 'Could not start review timing: ',
  '重新定位视频未返回视频信息': 'Relinking the video returned no video information',
  '最近项目目录不能为空': 'The recent-project directory cannot be empty',
  '当前快照尚未关联视频': 'The current snapshot is not linked to a video',
  '当前会话尚未关联视频': 'The current session is not linked to a video',
  '当前会话尚未创建项目': 'The current session has no project',
  '选择一段固定机位视频，系统会在最后一步统一应用配置。':
      'Choose a fixed-camera video first. Settings will be applied together in the final step.',
  '按步骤确认视频、分析范围和篮筐检测区域，最后再开始分析。':
      'Confirm the video, analysis range, and hoop detection regions step by step before analyzing.',
  '应用配置': 'Apply setup',
  '更换视频': 'Replace video',
  '重新定位视频': 'Relink video',
  '有数值但信号弱': 'A value is available, but the signal is weak',
  '请检查视频后重试': 'Check the video and try again',
  '反馈问题': 'Report a problem',
  '遇到问题或想提建议，两步就行：': 'Found a problem or have an idea? Two steps:',
  '复制诊断信息': 'Copy diagnostics',
  '会带上版本、系统和最近的运行日志，用户名会自动隐藏，不包含视频内容。':
      'Includes the version, system and recent logs. Your user name is hidden and no video content is included.',
  '发给我': 'Send it to me',
  '贴到交流群、小红书私信或邮件都可以，顺便说一下你做了什么操作。':
      'Paste it into the community group, a direct message or an email, and tell me what you were doing.',
  '错误详情': 'Error details',
  '已复制，可以粘贴发给我了': 'Copied. Paste it to me',
  '进交流群（官网扫码）': 'Community (website)',
  '发邮件': 'Email',
  'GitHub 提交': 'GitHub issue',
  '反馈这个问题': 'Report this problem',
  '遇到问题？点这里反馈': 'Something wrong? Report it here',
  '刚才出错了？点这里反馈': 'Just hit an error? Report it here',
  '点「反馈」可以一键复制诊断信息（版本、系统和运行日志），发到交流群或邮件给我，排查会快很多。':
      'Click Feedback to copy diagnostics (version, system and logs) in one step, then send them to me. It makes problems much faster to fix.',
  '现在反馈': 'Report now',
  '版本': 'Version',
  '检查更新': 'Check for updates',
  '正在检查更新…': 'Checking for updates…',
  '重新检查': 'Check again',
  '当前版本': 'Current version',
  '跳过这个版本': 'Skip this version',
  '稍后': 'Later',
  '下载更新': 'Download update',
  '后台下载': 'Download in background',
  '继续下载': 'Resume download',
  '打开安装包': 'Open installer',
  '打开所在文件夹': 'Show in folder',
  '下载完成。退出 BHE，把压缩包解压后替换原来的 BHE 文件夹，再重新打开。项目保存在别的位置，不会丢。':
      'Download complete. Quit BHE, unzip the package, replace the old BHE folder and open it again. Your projects are stored elsewhere and will not be lost.',
  '下载完成。退出 BHE，打开安装包把 BHE 拖进「应用程序」替换旧版本，再重新打开。项目保存在别的位置，不会丢。':
      'Download complete. Quit BHE, open the installer, drag BHE into Applications to replace the old version and open it again. Your projects are stored elsewhere and will not be lost.',
  '现在有分析或导出在进行，等它完成再退出替换。':
      'An analysis or export is running. Wait for it to finish before quitting to replace the app.',
  '点「查看」了解更新内容': 'Click View to see what is new',
  '查看': 'View',
  '连不上更新服务器，请检查网络': 'Cannot reach the update server. Check your network.',
  '更新信息签名校验失败': 'The update information failed its signature check.',
  '更新信息格式无效': 'The update information is invalid.',
  '下载中断，请检查网络后继续': 'The download was interrupted. Check your network and resume.',
  '安装包校验失败，请重新下载': 'The package failed its checksum. Download it again.',
  '安装更新': 'Install update',
  '安装并重启': 'Install and restart',
  '未能自动安装。可重试或打开所在文件夹手动更新。': 'Automatic installation failed. Retry or show the package in its folder to update manually.',
  '正在准备更新，请稍候…': 'Preparing the update. Please wait…',
  '请等待当前操作结束后再安装更新':
      'Wait for the current operation to finish before installing the update.',
  '退出前保存未完成，请重试': 'Could not save before exiting. Please try again.',
  '准备更新超时，请打开所在文件夹手动更新':
      'Update preparation timed out. Show the package in its folder to update manually.',
  '此平台请手动打开安装包更新': 'Open the installer to update on this platform.',
  '请在正式发布版 BHE 中安装更新': 'Install updates from a release build of BHE.',
  '下载完成。安装更新会保存当前项目、退出 BHE 并在更新后重新打开。旧版本会保留在原文件夹旁。':
      'Download complete. Installing saves your project, closes BHE and reopens it after the update. The previous version is kept beside the app folder.',
  '视频或项目文件夹可能被移动、改名或删除。请确认它还在原来的位置，必要时到导入页重新定位视频。':
      'The video or project folder may have been moved, renamed or deleted. Check that it is still there, and relink the video on the import page if needed.',
  '请确认文件没有被其它程序占用，或者换一个有读写权限的文件夹。':
      'Make sure no other program is using the file, or choose a folder you can read and write.',
  '磁盘空间不足': 'Not enough disk space',
  '请清理磁盘空间后再试。': 'Free up some disk space and try again.',
  '每个标签各合成一个视频': 'One video per tag',
  '只导出选中的标签，每个标签一个 MP4，文件名就是标签名，放进同一个文件夹。':
      'Exports only the selected tags: one MP4 per tag, named after the tag, in one folder.',
  '按标签导出': 'Per-tag export',
  '进球效果': 'Goal effect',
  '可选，导出时作用于每个进球片段': 'Optional. Applied to each goal clip when exporting.',
  '不加效果': 'No effect',
  '每个片段原样导出。': 'Clips are exported as they are.',
  '临门慢动作': 'Slow-motion approach',
  '进球前 1 秒放慢到一半速度，球进框后正常速度。人和球都在原画面里，像电影里的慢镜头。每个进球多约 1.3 秒。':
      'Slows down to half speed for the second before the goal, then back to normal once the ball is through. Players and ball stay in the frame, like a film slow-motion shot. Adds about 1.3 s per goal.',
  '慢放特写回放': 'Slow-motion close-up replay',
  '片段播完后，重播入框前后约 0.8 秒的画面：放慢一倍，取景框住篮筐和球的飞行路线，方便看清球进没进。每个进球多约 1.6 秒。':
      'After each clip, replays about 0.8 s around the goal at half speed, framed on the hoop and the ball path so you can see whether it went in. Adds about 1.6 s per goal.',
  '比赛数据': 'Game stats',
  '按当前审核结果统计': 'Based on the current review',
  '进球（保留）': 'Made (kept)',
  '其中未审核': 'Not reviewed yet',
  '你排除的': 'Excluded by you',
  '复核判定没进': 'Rim check: missed',
  '命中率（估算）': 'Hit rate (estimate)',
  '保留的进球 ÷ 全部疑似片段。疑似片段里也有不是投篮的，没碰到篮筐的投篮也不在里面，只是粗略估算。':
      'Kept goals ÷ all suspected clips. Some suspected clips are not shots, and shots that never reach the rim are missing, so this is only a rough estimate.',
  '每人进球': 'Made shots per player',
  '进球时间分布': 'Made shots over time',
  '源视频找不到，请到导入页重新定位视频': 'The source video cannot be found. Relink it on the import page.',
  '视频横竖方向已修正，篮筐和候选需要重新确认并分析': 'The video orientation was corrected. Re-confirm the hoop and candidates, then analyse again.',
  '现在有分析或导出在进行，等它完成再安装，安装时 BHE 会被关闭。':
      'An analysis or export is running. Wait for it to finish; installing closes BHE.',
  '下载完成。安装时 BHE 会被关闭，项目会保留。第一次安装需要允许 BHE「安装未知应用」。':
      'Download complete. Installing closes BHE and keeps your projects. The first time, allow BHE to install unknown apps.',
};
