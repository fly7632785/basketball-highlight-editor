// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'bhe_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class BheLocalizationsZh extends BheLocalizations {
  BheLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get reviewInvalidClipRange => '请输入有效时间：范围须在视频内，且时长至少为 1 秒。';

  @override
  String reviewRangeOpenFailed(String error) {
    return '无法暂停预览并打开范围编辑：$error';
  }

  @override
  String get appName => 'BHE';

  @override
  String get navProject => '项目';

  @override
  String get navImport => '导入';

  @override
  String get navReview => '审核';

  @override
  String get navExport => '导出';

  @override
  String get newProject => '新建项目';

  @override
  String get openPackage => '打开项目包';

  @override
  String get deleteProject => '删除当前项目';

  @override
  String get renameProject => '重命名项目';

  @override
  String get projectName => '项目名称';

  @override
  String get projectNameHint => '例如：10 月 24 日 训练赛';

  @override
  String get projectNameEmpty => '项目名称不能为空';

  @override
  String projectNameTooLong(int max) {
    return '项目名称最多 $max 个字符';
  }

  @override
  String get projectNameSaveFailed => '项目名称保存失败，请重试';

  @override
  String get projectNameScopeHint => '只修改显示名称，项目文件夹和已导出的视频不受影响。';

  @override
  String get save => '保存';

  @override
  String get cancel => '取消';

  @override
  String get close => '关闭';

  @override
  String get openFolder => '打开文件夹';

  @override
  String get projectInfo => '项目信息';

  @override
  String get projectCreatedAt => '创建时间';

  @override
  String get projectVideoCount => '视频段数';

  @override
  String get projectSegmentsUnit => '段';

  @override
  String get projectGoalsConfirmed => '已确认进球';

  @override
  String get projectStorageLocation => '存储位置';

  @override
  String get more => '更多';

  @override
  String get feedback => '反馈';

  @override
  String get feedbackMailClientMissing => '未找到可用的邮件客户端，请手动联系反馈邮箱。';

  @override
  String get about => '关于 BHE';

  @override
  String get backToProject => '返回项目';

  @override
  String get localProcessing => '本地处理';

  @override
  String get switchTheme => '切换主题';

  @override
  String get switchLanguage => '切换语言';

  @override
  String get languageChinese => '简体中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get taskInProgress => '任务仍在进行';

  @override
  String get confirmExit => '退出 BHE？';

  @override
  String get cancelTaskAndExit => '取消任务并退出';

  @override
  String get exitApp => '退出软件';

  @override
  String get returnAction => '返回';

  @override
  String get confirmCloseProject => '关闭当前项目？';

  @override
  String get closeProjectBusyDescription => '关闭项目会先取消当前任务，项目数据和原始视频不会被删除。';

  @override
  String get closeProjectDescription => '项目数据和原始视频会保留，下次可以从项目列表重新打开。';

  @override
  String get cancelTaskAndClose => '取消任务并关闭';

  @override
  String get closeProject => '关闭项目';

  @override
  String get engineReady => 'Engine 就绪';

  @override
  String get engineNotStarted => 'Engine 未启动';

  @override
  String get waitingEngine => '等待 Engine';

  @override
  String get engineError => 'Engine 错误';

  @override
  String get collapseSidebar => '收缩侧栏';

  @override
  String get expandSidebar => '展开侧栏';

  @override
  String get exitBusyDescription => '当前任务还在进行，退出前需要先取消任务。';

  @override
  String get exitDescription => '确认关闭软件吗？本地项目数据不会被删除。';

  @override
  String get pressBackAgainToExit => '再按一次返回键退出 BHE';

  @override
  String get homeHeadline => '把整场比赛，变成你的高光。';

  @override
  String get homeSubtitle =>
      '导入固定机位视频，本地分析候选进球，剔除误检后导出集锦。所有处理在本机完成，原始视频不会被复制或上传。';

  @override
  String get openProject => '打开项目';

  @override
  String get startFromVideoDescription =>
      '选择固定机位录像，同一场比赛的多段视频可以一起选。系统会自动定位篮筐，按顺序生成候选进球片段供你审核与导出。';

  @override
  String get videoDuration => '视频时长';

  @override
  String get recentProjects => '最近项目';

  @override
  String get refreshRecentProjects => '刷新最近项目';

  @override
  String get deleteProjectQuestion => '删除项目？';

  @override
  String deleteProjectDescription(Object name) {
    return '将删除“$name”的项目数据库、分析缓存和导出文件，原始视频不会被删除。';
  }

  @override
  String get noProjects => '还没有项目';

  @override
  String get recentProjectsLoadFailed => '加载最近项目失败';

  @override
  String get noProjectsDescription => '新建一个项目后，分析记录和导出历史会显示在这里。';

  @override
  String get exportHighlights => '导出集锦';

  @override
  String get exportDescription => '分析结果默认保留，导出时只排除你打叉的片段。';

  @override
  String get totalDuration => '合计时长';

  @override
  String get outputCodec => '输出编码';

  @override
  String get processingMethod => '处理方式';

  @override
  String get exportScope => '导出范围';

  @override
  String get allPlayers => '全部球员';

  @override
  String get unassigned => '未标记';

  @override
  String get reviewFilterPlayerTags => '筛选球员标签';

  @override
  String get reviewAllTags => '全部标签';

  @override
  String get reviewTagged => '已标记';

  @override
  String get reviewUntagged => '未标记';

  @override
  String reviewBatchRangeScope(int count) {
    return '应用范围：当前列表的 $count 个候选（随状态和球员标签筛选变化）';
  }

  @override
  String reviewFilterCount(int count, int total) {
    return '显示 $count / $total';
  }

  @override
  String get currentFilter => '当前筛选';

  @override
  String get cancelExport => '取消导出';

  @override
  String get analysisStillRunning => '视频仍在分析，分析完成后才能导出新的候选结果。';

  @override
  String get fastAnalysisRisk => '当前结果来自快速分析，可能漏检；如需更完整结果，建议先用标准模式重新分析。';

  @override
  String get dismissHint => '关闭提示';

  @override
  String get exportInterrupted => '上次导出已中断，可以从原设置重新导出。';

  @override
  String get projectWorkspace => '项目工作台';

  @override
  String get startVideoProject => '开始一个视频项目';

  @override
  String get selectVideo => '选择视频';

  @override
  String get localCompleteDescription => '本地完成分析、审核和导出。';

  @override
  String get configureAnalysisDescription => '配置好分析区域后即可开始识别。';

  @override
  String get prepareVideo => '正在准备视频';

  @override
  String get selectMatchVideo => '选择一段比赛视频';

  @override
  String get mobileCandidateDescription => 'BHE 会在本机生成候选片段，之后由你快速审核。';

  @override
  String get analysisConfig => '分析配置';

  @override
  String get autoSave => '自动保存';

  @override
  String get analysisQuality => '分析质量';

  @override
  String get clipDuration => '片段时长';

  @override
  String get roiZones => '投篮分析区与篮网区';

  @override
  String get notSet => '尚未设置';

  @override
  String get roiConfigured => '已设置，篮筐标定独立保存';

  @override
  String get analysisRange => '分析范围';

  @override
  String get noCandidatesAdvice => '没有找到候选片段。建议检查检测区域或分析范围后重新分析。';

  @override
  String get analysisInterrupted => '上次分析未完成，可以重新开始。';

  @override
  String get startAnalysis => '开始分析';

  @override
  String get redoAnalysis => '重新分析';

  @override
  String reviewCount(Object count) {
    return '审核 $count';
  }

  @override
  String lastAnalysisDuration(Object duration) {
    return '上次分析耗时 $duration';
  }

  @override
  String get startAnalysisTitle => '开始分析';

  @override
  String get foregroundAnalysisWarning =>
      '分析期间请保持 BHE 在前台并保持屏幕亮起。锁屏或切到后台可能导致分析变慢或暂停。';

  @override
  String get start => '开始';

  @override
  String get processingValue => '硬件编码优先，软件回退';

  @override
  String standardQuality(Object fps, Object size) {
    return '标准 · $size 输入 / ${fps}fps';
  }

  @override
  String highQuality(Object fps, Object size) {
    return '高质量 · $size 输入 / ${fps}fps';
  }

  @override
  String get analysisInProgress => '正在分析视频';

  @override
  String get checkingVideo => '检查视频';

  @override
  String get showTrajectory => '显示轨迹';

  @override
  String get hideTrajectory => '隐藏轨迹';

  @override
  String get shortcuts => '操作提示';

  @override
  String get moreReviewActions => '更多审核操作';

  @override
  String get editClipRange => '调整片段范围';

  @override
  String get viewEvidence => '查看判断依据';

  @override
  String get exportIncluded => '导出保留片段';

  @override
  String get replay => '重播';

  @override
  String get openAutoReplay => '打开自动重播';

  @override
  String get closeAutoReplay => '关闭自动重播';

  @override
  String get playbackSpeed => '播放速度';

  @override
  String get reviewMode => '审核';

  @override
  String get originalVideo => '原视频';

  @override
  String currentTime(Object time) {
    return '当前 $time';
  }

  @override
  String clipTime(Object end, Object start) {
    return '片段 $start — $end';
  }

  @override
  String fullVideoTime(Object duration) {
    return '全片 $duration';
  }

  @override
  String get include => '选中';

  @override
  String get exclude => '不选';

  @override
  String get statusConfirmed => '已确认';

  @override
  String get statusPending => '待审核';

  @override
  String candidateCount(Object count) {
    return '候选 $count';
  }

  @override
  String get addManualCandidate => '补漏';

  @override
  String get reviewComplete => '审核完成';

  @override
  String reviewCompleteDescription(Object count) {
    return '已处理 $count 个候选片段，可以进入导出。';
  }

  @override
  String get laterExport => '稍后导出';

  @override
  String get goExport => '去导出';

  @override
  String get productDescription => '从固定机位视频中识别投篮候选，审核后快速导出个人或全场高光。';

  @override
  String get feedbackEmail => '反馈邮箱';

  @override
  String get githubComingSoon => '即将开放';

  @override
  String get sendFeedback => '发送反馈';

  @override
  String projectStats(Object candidates, Object duration, Object included) {
    return '$included 保留 · $candidates 候选 · $duration';
  }

  @override
  String filterStats(Object count, Object duration) {
    return '$count 个 · $duration';
  }

  @override
  String get analysisLocalSaved => '分析在本机运行，完成后会自动保存结果。';

  @override
  String elapsed(Object duration) {
    return '已用 $duration';
  }

  @override
  String remaining(Object duration) {
    return '还需 $duration';
  }

  @override
  String get prepareLocalAnalysis => '准备本地分析';

  @override
  String processedFrames(Object processed, Object total) {
    return '$processed / $total 帧';
  }

  @override
  String get exportPageSubtitle => '按审核结果导出保留片段，可分别导出或合并为一条视频。';

  @override
  String get keptClips => '保留片段';

  @override
  String get output => '输出';

  @override
  String get playerExport => '按球员导出';

  @override
  String get optional => '可选';

  @override
  String get outputMode => '输出方式';

  @override
  String get mobileExportDescription => '当前移动端使用原视频分别导出，保留原始音频。';

  @override
  String get exportAllSeparately => '分别导出全部';

  @override
  String get mergeAllIncluded => '合并导出全部保留片段';

  @override
  String mergePlayerClips(Object player) {
    return '合并导出 $player 的片段';
  }

  @override
  String exportedClips(Object count) {
    return '已导出 $count 个片段';
  }

  @override
  String get configureProject => '配置分析项目';

  @override
  String get confirmProjectSteps => '按步骤确认视频、分析范围和篮筐检测区域，最后再开始分析。';

  @override
  String get chooseVideoLastStep => '先选择一段固定机位视频，系统会在最后一步统一应用配置。';

  @override
  String get relinkVideo => '重新定位视频';

  @override
  String get replaceVideo => '更换视频';

  @override
  String get nextStep => '下一步';

  @override
  String get confirmAndStartAnalysis => '确认配置并开始分析';

  @override
  String get detectRegionStep => '检测区域';

  @override
  String get confirm => '确认';

  @override
  String get rangeEditorHint =>
      '播放片段会在范围内循环；拖动两端、拖到边缘可继续延长，或用 I / O 把当前位置设为开始 / 结束。原视频不会被修改。';

  @override
  String get rangeManualHint => '已定位到原视频当前时间。用 I / O 设定开始和结束后加入候选。';

  @override
  String get rangePlayClip => '播放片段（Space）';

  @override
  String get rangePause => '暂停（Space）';

  @override
  String get rangePreviewEnding => '预览结尾';

  @override
  String get rangeStatusInside => '范围内';

  @override
  String get rangeStatusBefore => '范围前';

  @override
  String get rangeStatusAfter => '范围后';

  @override
  String rangePosition(String time) {
    return '当前位置 $time';
  }

  @override
  String rangeSummary(String start, String end, String duration) {
    return '片段 $start – $end · $duration';
  }

  @override
  String get rangeSetStart => '设为开始（I）';

  @override
  String get rangeSetEnd => '设为结束（O）';

  @override
  String get rangeExtendStart => '开头 −2 秒';

  @override
  String get rangeExtendEnd => '结尾 +2 秒';

  @override
  String get rangeExtendBoth => '前后各 +2 秒';

  @override
  String get rangeLegendEvent => '进球时刻';

  @override
  String get rangeLegendOriginal => '原范围';

  @override
  String get rangeTimelineLabel => '片段时间轴';

  @override
  String get reviewStatusAll => '全部';

  @override
  String get reviewStatusKept => '保留';

  @override
  String get reviewStatusExcluded => '排除';

  @override
  String get reviewStatusFilter => '按保留／排除筛选';

  @override
  String get reviewClearFilters => '清除筛选';

  @override
  String get reviewMoreActions => '更多操作';

  @override
  String get reviewAddMissed => '补漏片段';

  @override
  String get reviewKeepAction => '保留';

  @override
  String get reviewExcludeAction => '排除';

  @override
  String get reviewWillExport => '会导出';

  @override
  String get reviewWillNotExport => '不会导出';

  @override
  String get reviewUndoLast => '撤销上一步';

  @override
  String get reviewAdjustRange => '调整范围';

  @override
  String get reviewNote => '备注';

  @override
  String get reviewScores => '评分';

  @override
  String get reviewSignals => '信号';

  @override
  String get reviewCurrentClip => '当前片段';

  @override
  String get reviewAnalysisDetails => '分析详情';

  @override
  String get exportOutputMode => '输出方式';

  @override
  String get exportMergeTitle => '合并成一个视频';

  @override
  String get exportMergeDescription => '按时间顺序拼接为一个 MP4，适合直接分享。';

  @override
  String get exportSeparateTitle => '每个片段单独导出';

  @override
  String get exportSeparateDescription => '每段一个文件，放进同一个文件夹，适合二次剪辑。';

  @override
  String exportStartButton(int count) {
    return '导出 $count 个片段';
  }

  @override
  String get exportStartHint => '下一步选择保存位置，已排除的片段不会进入输出。';

  @override
  String get exportClipCount => '片段';

  @override
  String get exportScopeHint => '可多选球员';

  @override
  String get exportRecent => '最近导出';

  @override
  String get exportRunningTitle => '正在导出';

  @override
  String get homeContinueTitle => '继续上次';

  @override
  String get homeContinueReview => '继续审核';

  @override
  String get homeContinueSetup => '继续配置';

  @override
  String get homeNoCurrentProject => '还没有打开的项目';

  @override
  String get homeNoCurrentProjectDescription => '新建项目，或从下方最近项目中打开一个继续。';

  @override
  String get homeSupportedFormats => 'MP4 · MOV · M4V · AVI · MKV · 原始视频不会被修改';

  @override
  String get homeCandidates => '候选';

  @override
  String get homeKept => '保留';

  @override
  String get homeExcluded => '排除';

  @override
  String get homeStatusPending => '待审核';

  @override
  String get homeStatusExported => '已导出';

  @override
  String get homeStatusEmpty => '暂无候选';

  @override
  String get homeStatusMissingVideo => '视频缺失';

  @override
  String get homeStatusAnalyzing => '分析中';

  @override
  String get homeProjectActions => '项目操作';

  @override
  String importNextTo(String step) {
    return '下一步：$step';
  }

  @override
  String get importConfirmStep => '确认并分析';

  @override
  String get importReplacesCandidates => '已有候选会被本次结果替换';

  @override
  String get importRangeAnalyzed => '分析时长';

  @override
  String get importRangeExcluded => '已排除';

  @override
  String importRangeCoverage(String total, int percent) {
    return '全片 $total · 分析其中 $percent%';
  }

  @override
  String get importSetStart => '设为起点';

  @override
  String get importSetEnd => '设为终点';

  @override
  String get importSummaryTitle => '配置摘要';

  @override
  String get importEdit => '修改';

  @override
  String get importAnalysisMode => '分析模式';

  @override
  String get importStandardDescription => '完整检测，漏检更少。';

  @override
  String get importFastDescription => '使用低规格代理，更快，但可能漏检少量片段。';

  @override
  String get importRecommended => '推荐';

  @override
  String get importClipLengthHint => '审核时仍可单独调整每个片段';

  @override
  String importClipTotal(int seconds) {
    return '每段 $seconds 秒';
  }

  @override
  String importEstimate(String estimate) {
    return '预计耗时 $estimate · 实际受视频编码、磁盘和设备负载影响';
  }

  @override
  String reviewProgress(int done, int total) {
    return '已审核 $done / $total';
  }

  @override
  String get reviewUnreviewed => '未审核';

  @override
  String get homeDropHint => '也可以把一段或多段视频拖到这里';

  @override
  String get homeDropActive => '松开即可新建项目';

  @override
  String get homeDropUnsupported => '不支持这个文件，请拖入 MP4、MOV、M4V、AVI 或 MKV 视频';
}
