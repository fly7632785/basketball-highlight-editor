// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'bhe_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class BheLocalizationsZh extends BheLocalizations {
  BheLocalizationsZh([String locale = 'zh']) : super(locale);

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
  String get startFromVideo => '从视频开始';

  @override
  String get openProject => '打开项目';

  @override
  String get startFromVideoDescription =>
      '选择一段固定机位录像，系统会优先自动定位篮筐，随后生成候选进球片段供你审核与导出。';

  @override
  String get currentProject => '当前项目';

  @override
  String get includedCount => '当前保留';

  @override
  String get excludedCount => '已排除';

  @override
  String get videoDuration => '视频时长';

  @override
  String get localDatabaseNote => '本地 SQLite · 原始视频不复制';

  @override
  String get recentProjects => '最近项目';

  @override
  String get refreshRecentProjects => '刷新最近项目';

  @override
  String get workflow => '工作流';

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
  String get importVideoStep => '导入视频';

  @override
  String get roiStep => '框选 ROI';

  @override
  String get analysisStep => '分析扫描';

  @override
  String get reviewStep => '审核候选';

  @override
  String get exportHighlightsStep => '导出集锦';

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
  String get cancel => '取消';

  @override
  String get close => '关闭';
}
