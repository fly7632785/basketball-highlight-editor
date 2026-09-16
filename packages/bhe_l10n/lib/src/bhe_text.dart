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
  final allCandidates = RegExp(r'^全部 (\d+) 个候选片段$').firstMatch(source);
  if (allCandidates != null)
    return 'All ${allCandidates.group(1)} candidate clips';
  final allReviewCandidates = RegExp(r'^全部候选 · (\d+) 个$').firstMatch(source);
  if (allReviewCandidates != null) {
    return 'All candidates · ${allReviewCandidates.group(1)}';
  }
  final checkedCandidates = RegExp(r'^已勾选候选 · (\d+) 个$').firstMatch(source);
  if (checkedCandidates != null) {
    return 'Checked candidates · ${checkedCandidates.group(1)}';
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
  final includedCount = RegExp(r'^已选 (\d+) / (\d+)$').firstMatch(source);
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
    r'^(合并导出|分别导出) · (\d+) 个片段 · (.+)$',
  ).firstMatch(source);
  if (exportSummary != null) {
    final mode = exportSummary.group(1) == '合并导出'
        ? 'Merged export'
        : 'Separate exports';
    return '$mode · ${exportSummary.group(2)} clips · ${exportSummary.group(3)}';
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
    r'^候选 (\d+)，(.+)，(已排除|已保留)$',
  ).firstMatch(source);
  if (candidateAria != null) {
    final status = candidateAria.group(3) == '已排除' ? 'excluded' : 'included';
    return 'Candidate ${candidateAria.group(1)}, ${candidateAria.group(2)}, $status';
  }
  final candidateAt = RegExp(r'^候选 (.+)$').firstMatch(source);
  if (candidateAt != null) return 'Candidate ${candidateAt.group(1)}';
  final duration = RegExp(r'^时长 (.+)$').firstMatch(source);
  if (duration != null) return 'Duration ${_englishDuration(duration.group(1)!)}';
  final batchCount = RegExp(r'^批量 (\d+) 个$').firstMatch(source);
  if (batchCount != null) return 'Bulk ${batchCount.group(1)}';
  final selectedBatch = RegExp(r'^已勾选候选 · (\d+) 个$').firstMatch(source);
  if (selectedBatch != null) return 'Checked candidates · ${selectedBatch.group(1)}';
  final selectedCount = RegExp(r'^已选 (\d+) / (\d+)$').firstMatch(source);
  if (selectedCount != null) {
    return 'Included ${selectedCount.group(1)} / ${selectedCount.group(2)}';
  }
  final appliedBatch = RegExp(r'^已更新 (\d+) 个片段的球员标签$').firstMatch(source);
  if (appliedBatch != null) return 'Updated player tags for ${appliedBatch.group(1)} clips';
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
  '分析完成': 'Analysis complete',
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
  '排除片段 (X / Backspace)': 'Exclude clip (X / Backspace)',
  '设置球员标签': 'Set player tag',
  '未标记': 'Untagged',
  '退出批量选择': 'Exit batch selection',
  '批量选择候选': 'Select candidates in bulk',
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
  '正在准备本地模型': 'Preparing the local model',
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
  '设置批量球员标签': 'Set player tags in bulk',
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
  '快捷键\nSpace  播放/暂停\nR  重播当前\nL  循环当前\nA  显示/关闭标注\n↑ / ↓  切换候选\n← / →  快退/快进 2 秒\nC / Enter  保留\nX / Backspace  排除\nCmd/Ctrl+Z  撤销':
      'Shortcuts\nSpace  Play/pause\nR  Replay current\nL  Loop current\nA  Show/hide annotations\n↑ / ↓  Switch candidates\n← / →  Rewind/forward 2 sec\nC / Enter  Include\nX / Backspace  Exclude\nCmd/Ctrl+Z  Undo',
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
  '应用范围': 'Apply to',
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
  'Engine 尚未启动': 'Engine has not started',
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
  '球员已删除': 'Player deleted',
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
};
