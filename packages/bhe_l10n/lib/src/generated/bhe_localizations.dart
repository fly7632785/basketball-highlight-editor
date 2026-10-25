import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'bhe_localizations_en.dart';
import 'bhe_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of BheLocalizations
/// returned by `BheLocalizations.of(context)`.
///
/// Applications need to include `BheLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/bhe_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: BheLocalizations.localizationsDelegates,
///   supportedLocales: BheLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the BheLocalizations.supportedLocales
/// property.
abstract class BheLocalizations {
  BheLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static BheLocalizations of(BuildContext context) {
    return Localizations.of<BheLocalizations>(context, BheLocalizations)!;
  }

  static const LocalizationsDelegate<BheLocalizations> delegate =
      _BheLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @reviewInvalidClipRange.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效时间：范围须在视频内，且时长至少为 1 秒。'**
  String get reviewInvalidClipRange;

  /// No description provided for @reviewRangeOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法暂停预览并打开范围编辑：{error}'**
  String reviewRangeOpenFailed(String error);

  /// No description provided for @appName.
  ///
  /// In zh, this message translates to:
  /// **'BHE'**
  String get appName;

  /// No description provided for @navProject.
  ///
  /// In zh, this message translates to:
  /// **'项目'**
  String get navProject;

  /// No description provided for @navImport.
  ///
  /// In zh, this message translates to:
  /// **'导入'**
  String get navImport;

  /// No description provided for @navReview.
  ///
  /// In zh, this message translates to:
  /// **'审核'**
  String get navReview;

  /// No description provided for @navExport.
  ///
  /// In zh, this message translates to:
  /// **'导出'**
  String get navExport;

  /// No description provided for @newProject.
  ///
  /// In zh, this message translates to:
  /// **'新建项目'**
  String get newProject;

  /// No description provided for @openPackage.
  ///
  /// In zh, this message translates to:
  /// **'打开项目包'**
  String get openPackage;

  /// No description provided for @deleteProject.
  ///
  /// In zh, this message translates to:
  /// **'删除当前项目'**
  String get deleteProject;

  /// No description provided for @renameProject.
  ///
  /// In zh, this message translates to:
  /// **'重命名项目'**
  String get renameProject;

  /// No description provided for @projectName.
  ///
  /// In zh, this message translates to:
  /// **'项目名称'**
  String get projectName;

  /// No description provided for @projectNameHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：10 月 24 日 训练赛'**
  String get projectNameHint;

  /// No description provided for @projectNameEmpty.
  ///
  /// In zh, this message translates to:
  /// **'项目名称不能为空'**
  String get projectNameEmpty;

  /// No description provided for @projectNameTooLong.
  ///
  /// In zh, this message translates to:
  /// **'项目名称最多 {max} 个字符'**
  String projectNameTooLong(int max);

  /// No description provided for @projectNameSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'项目名称保存失败，请重试'**
  String get projectNameSaveFailed;

  /// No description provided for @projectNameScopeHint.
  ///
  /// In zh, this message translates to:
  /// **'只修改显示名称，项目文件夹和已导出的视频不受影响。'**
  String get projectNameScopeHint;

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @close.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get close;

  /// No description provided for @openFolder.
  ///
  /// In zh, this message translates to:
  /// **'打开文件夹'**
  String get openFolder;

  /// No description provided for @projectInfo.
  ///
  /// In zh, this message translates to:
  /// **'项目信息'**
  String get projectInfo;

  /// No description provided for @projectCreatedAt.
  ///
  /// In zh, this message translates to:
  /// **'创建时间'**
  String get projectCreatedAt;

  /// No description provided for @projectVideoCount.
  ///
  /// In zh, this message translates to:
  /// **'视频段数'**
  String get projectVideoCount;

  /// No description provided for @projectSegmentsUnit.
  ///
  /// In zh, this message translates to:
  /// **'段'**
  String get projectSegmentsUnit;

  /// No description provided for @projectGoalsConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已确认进球'**
  String get projectGoalsConfirmed;

  /// No description provided for @projectStorageLocation.
  ///
  /// In zh, this message translates to:
  /// **'存储位置'**
  String get projectStorageLocation;

  /// No description provided for @more.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get more;

  /// No description provided for @feedback.
  ///
  /// In zh, this message translates to:
  /// **'反馈'**
  String get feedback;

  /// No description provided for @feedbackMailClientMissing.
  ///
  /// In zh, this message translates to:
  /// **'未找到可用的邮件客户端，请手动联系反馈邮箱。'**
  String get feedbackMailClientMissing;

  /// No description provided for @about.
  ///
  /// In zh, this message translates to:
  /// **'关于 BHE'**
  String get about;

  /// No description provided for @backToProject.
  ///
  /// In zh, this message translates to:
  /// **'返回项目'**
  String get backToProject;

  /// No description provided for @localProcessing.
  ///
  /// In zh, this message translates to:
  /// **'本地处理'**
  String get localProcessing;

  /// No description provided for @switchTheme.
  ///
  /// In zh, this message translates to:
  /// **'切换主题'**
  String get switchTheme;

  /// No description provided for @switchLanguage.
  ///
  /// In zh, this message translates to:
  /// **'切换语言'**
  String get switchLanguage;

  /// No description provided for @languageChinese.
  ///
  /// In zh, this message translates to:
  /// **'简体中文'**
  String get languageChinese;

  /// No description provided for @languageEnglish.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @taskInProgress.
  ///
  /// In zh, this message translates to:
  /// **'任务仍在进行'**
  String get taskInProgress;

  /// No description provided for @confirmExit.
  ///
  /// In zh, this message translates to:
  /// **'退出 BHE？'**
  String get confirmExit;

  /// No description provided for @cancelTaskAndExit.
  ///
  /// In zh, this message translates to:
  /// **'取消任务并退出'**
  String get cancelTaskAndExit;

  /// No description provided for @exitApp.
  ///
  /// In zh, this message translates to:
  /// **'退出软件'**
  String get exitApp;

  /// No description provided for @returnAction.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get returnAction;

  /// No description provided for @confirmCloseProject.
  ///
  /// In zh, this message translates to:
  /// **'关闭当前项目？'**
  String get confirmCloseProject;

  /// No description provided for @closeProjectBusyDescription.
  ///
  /// In zh, this message translates to:
  /// **'关闭项目会先取消当前任务，项目数据和原始视频不会被删除。'**
  String get closeProjectBusyDescription;

  /// No description provided for @closeProjectDescription.
  ///
  /// In zh, this message translates to:
  /// **'项目数据和原始视频会保留，下次可以从项目列表重新打开。'**
  String get closeProjectDescription;

  /// No description provided for @cancelTaskAndClose.
  ///
  /// In zh, this message translates to:
  /// **'取消任务并关闭'**
  String get cancelTaskAndClose;

  /// No description provided for @closeProject.
  ///
  /// In zh, this message translates to:
  /// **'关闭项目'**
  String get closeProject;

  /// No description provided for @engineReady.
  ///
  /// In zh, this message translates to:
  /// **'Engine 就绪'**
  String get engineReady;

  /// No description provided for @engineNotStarted.
  ///
  /// In zh, this message translates to:
  /// **'Engine 未启动'**
  String get engineNotStarted;

  /// No description provided for @waitingEngine.
  ///
  /// In zh, this message translates to:
  /// **'等待 Engine'**
  String get waitingEngine;

  /// No description provided for @engineError.
  ///
  /// In zh, this message translates to:
  /// **'Engine 错误'**
  String get engineError;

  /// No description provided for @collapseSidebar.
  ///
  /// In zh, this message translates to:
  /// **'收缩侧栏'**
  String get collapseSidebar;

  /// No description provided for @expandSidebar.
  ///
  /// In zh, this message translates to:
  /// **'展开侧栏'**
  String get expandSidebar;

  /// No description provided for @exitBusyDescription.
  ///
  /// In zh, this message translates to:
  /// **'当前任务还在进行，退出前需要先取消任务。'**
  String get exitBusyDescription;

  /// No description provided for @exitDescription.
  ///
  /// In zh, this message translates to:
  /// **'确认关闭软件吗？本地项目数据不会被删除。'**
  String get exitDescription;

  /// No description provided for @pressBackAgainToExit.
  ///
  /// In zh, this message translates to:
  /// **'再按一次返回键退出 BHE'**
  String get pressBackAgainToExit;

  /// No description provided for @homeHeadline.
  ///
  /// In zh, this message translates to:
  /// **'把整场比赛，变成你的高光。'**
  String get homeHeadline;

  /// No description provided for @homeSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'导入固定机位视频，本地分析候选进球，剔除误检后导出集锦。所有处理在本机完成，原始视频不会被复制或上传。'**
  String get homeSubtitle;

  /// No description provided for @openProject.
  ///
  /// In zh, this message translates to:
  /// **'打开项目'**
  String get openProject;

  /// No description provided for @startFromVideoDescription.
  ///
  /// In zh, this message translates to:
  /// **'选择固定机位录像，同一场比赛的多段视频可以一起选。系统会自动定位篮筐，按顺序生成候选进球片段供你审核与导出。'**
  String get startFromVideoDescription;

  /// No description provided for @videoDuration.
  ///
  /// In zh, this message translates to:
  /// **'视频时长'**
  String get videoDuration;

  /// No description provided for @recentProjects.
  ///
  /// In zh, this message translates to:
  /// **'最近项目'**
  String get recentProjects;

  /// No description provided for @refreshRecentProjects.
  ///
  /// In zh, this message translates to:
  /// **'刷新最近项目'**
  String get refreshRecentProjects;

  /// No description provided for @deleteProjectQuestion.
  ///
  /// In zh, this message translates to:
  /// **'删除项目？'**
  String get deleteProjectQuestion;

  /// No description provided for @deleteProjectDescription.
  ///
  /// In zh, this message translates to:
  /// **'将删除“{name}”的项目数据库、分析缓存和导出文件，原始视频不会被删除。'**
  String deleteProjectDescription(Object name);

  /// No description provided for @noProjects.
  ///
  /// In zh, this message translates to:
  /// **'还没有项目'**
  String get noProjects;

  /// No description provided for @recentProjectsLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载最近项目失败'**
  String get recentProjectsLoadFailed;

  /// No description provided for @noProjectsDescription.
  ///
  /// In zh, this message translates to:
  /// **'新建一个项目后，分析记录和导出历史会显示在这里。'**
  String get noProjectsDescription;

  /// No description provided for @exportHighlights.
  ///
  /// In zh, this message translates to:
  /// **'导出集锦'**
  String get exportHighlights;

  /// No description provided for @exportDescription.
  ///
  /// In zh, this message translates to:
  /// **'分析结果默认保留，导出时只排除你打叉的片段。'**
  String get exportDescription;

  /// No description provided for @totalDuration.
  ///
  /// In zh, this message translates to:
  /// **'合计时长'**
  String get totalDuration;

  /// No description provided for @outputCodec.
  ///
  /// In zh, this message translates to:
  /// **'输出编码'**
  String get outputCodec;

  /// No description provided for @processingMethod.
  ///
  /// In zh, this message translates to:
  /// **'处理方式'**
  String get processingMethod;

  /// No description provided for @exportScope.
  ///
  /// In zh, this message translates to:
  /// **'导出范围'**
  String get exportScope;

  /// No description provided for @allPlayers.
  ///
  /// In zh, this message translates to:
  /// **'全部球员'**
  String get allPlayers;

  /// No description provided for @unassigned.
  ///
  /// In zh, this message translates to:
  /// **'未标记'**
  String get unassigned;

  /// No description provided for @reviewFilterPlayerTags.
  ///
  /// In zh, this message translates to:
  /// **'筛选球员标签'**
  String get reviewFilterPlayerTags;

  /// No description provided for @reviewAllTags.
  ///
  /// In zh, this message translates to:
  /// **'全部标签'**
  String get reviewAllTags;

  /// No description provided for @reviewTagged.
  ///
  /// In zh, this message translates to:
  /// **'已标记'**
  String get reviewTagged;

  /// No description provided for @reviewUntagged.
  ///
  /// In zh, this message translates to:
  /// **'未标记'**
  String get reviewUntagged;

  /// No description provided for @reviewBatchRangeScope.
  ///
  /// In zh, this message translates to:
  /// **'应用范围：当前列表的 {count} 个候选（随状态和球员标签筛选变化）'**
  String reviewBatchRangeScope(int count);

  /// No description provided for @reviewFilterCount.
  ///
  /// In zh, this message translates to:
  /// **'显示 {count} / {total}'**
  String reviewFilterCount(int count, int total);

  /// No description provided for @currentFilter.
  ///
  /// In zh, this message translates to:
  /// **'当前筛选'**
  String get currentFilter;

  /// No description provided for @cancelExport.
  ///
  /// In zh, this message translates to:
  /// **'取消导出'**
  String get cancelExport;

  /// No description provided for @analysisStillRunning.
  ///
  /// In zh, this message translates to:
  /// **'视频仍在分析，分析完成后才能导出新的候选结果。'**
  String get analysisStillRunning;

  /// No description provided for @fastAnalysisRisk.
  ///
  /// In zh, this message translates to:
  /// **'当前结果来自快速分析，可能漏检；如需更完整结果，建议先用标准模式重新分析。'**
  String get fastAnalysisRisk;

  /// No description provided for @dismissHint.
  ///
  /// In zh, this message translates to:
  /// **'关闭提示'**
  String get dismissHint;

  /// No description provided for @exportInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'上次导出已中断，可以从原设置重新导出。'**
  String get exportInterrupted;

  /// No description provided for @projectWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'项目工作台'**
  String get projectWorkspace;

  /// No description provided for @startVideoProject.
  ///
  /// In zh, this message translates to:
  /// **'开始一个视频项目'**
  String get startVideoProject;

  /// No description provided for @selectVideo.
  ///
  /// In zh, this message translates to:
  /// **'选择视频'**
  String get selectVideo;

  /// No description provided for @localCompleteDescription.
  ///
  /// In zh, this message translates to:
  /// **'本地完成分析、审核和导出。'**
  String get localCompleteDescription;

  /// No description provided for @configureAnalysisDescription.
  ///
  /// In zh, this message translates to:
  /// **'配置好分析区域后即可开始识别。'**
  String get configureAnalysisDescription;

  /// No description provided for @prepareVideo.
  ///
  /// In zh, this message translates to:
  /// **'正在准备视频'**
  String get prepareVideo;

  /// No description provided for @selectMatchVideo.
  ///
  /// In zh, this message translates to:
  /// **'选择一段比赛视频'**
  String get selectMatchVideo;

  /// No description provided for @mobileCandidateDescription.
  ///
  /// In zh, this message translates to:
  /// **'BHE 会在本机生成候选片段，之后由你快速审核。'**
  String get mobileCandidateDescription;

  /// No description provided for @analysisConfig.
  ///
  /// In zh, this message translates to:
  /// **'分析配置'**
  String get analysisConfig;

  /// No description provided for @autoSave.
  ///
  /// In zh, this message translates to:
  /// **'自动保存'**
  String get autoSave;

  /// No description provided for @analysisQuality.
  ///
  /// In zh, this message translates to:
  /// **'分析质量'**
  String get analysisQuality;

  /// No description provided for @clipDuration.
  ///
  /// In zh, this message translates to:
  /// **'片段时长'**
  String get clipDuration;

  /// No description provided for @roiZones.
  ///
  /// In zh, this message translates to:
  /// **'投篮分析区与篮网区'**
  String get roiZones;

  /// No description provided for @notSet.
  ///
  /// In zh, this message translates to:
  /// **'尚未设置'**
  String get notSet;

  /// No description provided for @roiConfigured.
  ///
  /// In zh, this message translates to:
  /// **'已设置，篮筐标定独立保存'**
  String get roiConfigured;

  /// No description provided for @analysisRange.
  ///
  /// In zh, this message translates to:
  /// **'分析范围'**
  String get analysisRange;

  /// No description provided for @noCandidatesAdvice.
  ///
  /// In zh, this message translates to:
  /// **'没有找到候选片段。建议检查检测区域或分析范围后重新分析。'**
  String get noCandidatesAdvice;

  /// No description provided for @analysisInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'上次分析未完成，可以重新开始。'**
  String get analysisInterrupted;

  /// No description provided for @startAnalysis.
  ///
  /// In zh, this message translates to:
  /// **'开始分析'**
  String get startAnalysis;

  /// No description provided for @redoAnalysis.
  ///
  /// In zh, this message translates to:
  /// **'重新分析'**
  String get redoAnalysis;

  /// No description provided for @reviewCount.
  ///
  /// In zh, this message translates to:
  /// **'审核 {count}'**
  String reviewCount(Object count);

  /// No description provided for @lastAnalysisDuration.
  ///
  /// In zh, this message translates to:
  /// **'上次分析耗时 {duration}'**
  String lastAnalysisDuration(Object duration);

  /// No description provided for @startAnalysisTitle.
  ///
  /// In zh, this message translates to:
  /// **'开始分析'**
  String get startAnalysisTitle;

  /// No description provided for @foregroundAnalysisWarning.
  ///
  /// In zh, this message translates to:
  /// **'分析期间请保持 BHE 在前台并保持屏幕亮起。锁屏或切到后台可能导致分析变慢或暂停。'**
  String get foregroundAnalysisWarning;

  /// No description provided for @start.
  ///
  /// In zh, this message translates to:
  /// **'开始'**
  String get start;

  /// No description provided for @processingValue.
  ///
  /// In zh, this message translates to:
  /// **'硬件编码优先，软件回退'**
  String get processingValue;

  /// No description provided for @standardQuality.
  ///
  /// In zh, this message translates to:
  /// **'标准 · {size} 输入 / {fps}fps'**
  String standardQuality(Object fps, Object size);

  /// No description provided for @highQuality.
  ///
  /// In zh, this message translates to:
  /// **'高质量 · {size} 输入 / {fps}fps'**
  String highQuality(Object fps, Object size);

  /// No description provided for @analysisInProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在分析视频'**
  String get analysisInProgress;

  /// No description provided for @checkingVideo.
  ///
  /// In zh, this message translates to:
  /// **'检查视频'**
  String get checkingVideo;

  /// No description provided for @showTrajectory.
  ///
  /// In zh, this message translates to:
  /// **'显示轨迹'**
  String get showTrajectory;

  /// No description provided for @hideTrajectory.
  ///
  /// In zh, this message translates to:
  /// **'隐藏轨迹'**
  String get hideTrajectory;

  /// No description provided for @shortcuts.
  ///
  /// In zh, this message translates to:
  /// **'操作提示'**
  String get shortcuts;

  /// No description provided for @moreReviewActions.
  ///
  /// In zh, this message translates to:
  /// **'更多审核操作'**
  String get moreReviewActions;

  /// No description provided for @editClipRange.
  ///
  /// In zh, this message translates to:
  /// **'调整片段范围'**
  String get editClipRange;

  /// No description provided for @viewEvidence.
  ///
  /// In zh, this message translates to:
  /// **'查看判断依据'**
  String get viewEvidence;

  /// No description provided for @exportIncluded.
  ///
  /// In zh, this message translates to:
  /// **'导出保留片段'**
  String get exportIncluded;

  /// No description provided for @replay.
  ///
  /// In zh, this message translates to:
  /// **'重播'**
  String get replay;

  /// No description provided for @openAutoReplay.
  ///
  /// In zh, this message translates to:
  /// **'打开自动重播'**
  String get openAutoReplay;

  /// No description provided for @closeAutoReplay.
  ///
  /// In zh, this message translates to:
  /// **'关闭自动重播'**
  String get closeAutoReplay;

  /// No description provided for @playbackSpeed.
  ///
  /// In zh, this message translates to:
  /// **'播放速度'**
  String get playbackSpeed;

  /// No description provided for @reviewMode.
  ///
  /// In zh, this message translates to:
  /// **'审核'**
  String get reviewMode;

  /// No description provided for @originalVideo.
  ///
  /// In zh, this message translates to:
  /// **'原视频'**
  String get originalVideo;

  /// No description provided for @currentTime.
  ///
  /// In zh, this message translates to:
  /// **'当前 {time}'**
  String currentTime(Object time);

  /// No description provided for @clipTime.
  ///
  /// In zh, this message translates to:
  /// **'片段 {start} — {end}'**
  String clipTime(Object end, Object start);

  /// No description provided for @fullVideoTime.
  ///
  /// In zh, this message translates to:
  /// **'全片 {duration}'**
  String fullVideoTime(Object duration);

  /// No description provided for @include.
  ///
  /// In zh, this message translates to:
  /// **'选中'**
  String get include;

  /// No description provided for @exclude.
  ///
  /// In zh, this message translates to:
  /// **'不选'**
  String get exclude;

  /// No description provided for @statusConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已确认'**
  String get statusConfirmed;

  /// No description provided for @statusPending.
  ///
  /// In zh, this message translates to:
  /// **'待审核'**
  String get statusPending;

  /// No description provided for @candidateCount.
  ///
  /// In zh, this message translates to:
  /// **'候选 {count}'**
  String candidateCount(Object count);

  /// No description provided for @addManualCandidate.
  ///
  /// In zh, this message translates to:
  /// **'补漏'**
  String get addManualCandidate;

  /// No description provided for @reviewComplete.
  ///
  /// In zh, this message translates to:
  /// **'审核完成'**
  String get reviewComplete;

  /// No description provided for @reviewCompleteDescription.
  ///
  /// In zh, this message translates to:
  /// **'已处理 {count} 个候选片段，可以进入导出。'**
  String reviewCompleteDescription(Object count);

  /// No description provided for @laterExport.
  ///
  /// In zh, this message translates to:
  /// **'稍后导出'**
  String get laterExport;

  /// No description provided for @goExport.
  ///
  /// In zh, this message translates to:
  /// **'去导出'**
  String get goExport;

  /// No description provided for @productDescription.
  ///
  /// In zh, this message translates to:
  /// **'从固定机位视频中识别投篮候选，审核后快速导出个人或全场高光。'**
  String get productDescription;

  /// No description provided for @feedbackEmail.
  ///
  /// In zh, this message translates to:
  /// **'反馈邮箱'**
  String get feedbackEmail;

  /// No description provided for @githubComingSoon.
  ///
  /// In zh, this message translates to:
  /// **'即将开放'**
  String get githubComingSoon;

  /// No description provided for @sendFeedback.
  ///
  /// In zh, this message translates to:
  /// **'发送反馈'**
  String get sendFeedback;

  /// No description provided for @projectStats.
  ///
  /// In zh, this message translates to:
  /// **'{included} 保留 · {candidates} 候选 · {duration}'**
  String projectStats(Object candidates, Object duration, Object included);

  /// No description provided for @filterStats.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个 · {duration}'**
  String filterStats(Object count, Object duration);

  /// No description provided for @analysisLocalSaved.
  ///
  /// In zh, this message translates to:
  /// **'分析在本机运行，完成后会自动保存结果。'**
  String get analysisLocalSaved;

  /// No description provided for @elapsed.
  ///
  /// In zh, this message translates to:
  /// **'已用 {duration}'**
  String elapsed(Object duration);

  /// No description provided for @remaining.
  ///
  /// In zh, this message translates to:
  /// **'还需 {duration}'**
  String remaining(Object duration);

  /// No description provided for @prepareLocalAnalysis.
  ///
  /// In zh, this message translates to:
  /// **'准备本地分析'**
  String get prepareLocalAnalysis;

  /// No description provided for @processedFrames.
  ///
  /// In zh, this message translates to:
  /// **'{processed} / {total} 帧'**
  String processedFrames(Object processed, Object total);

  /// No description provided for @exportPageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'按审核结果导出保留片段，可分别导出或合并为一条视频。'**
  String get exportPageSubtitle;

  /// No description provided for @keptClips.
  ///
  /// In zh, this message translates to:
  /// **'保留片段'**
  String get keptClips;

  /// No description provided for @output.
  ///
  /// In zh, this message translates to:
  /// **'输出'**
  String get output;

  /// No description provided for @playerExport.
  ///
  /// In zh, this message translates to:
  /// **'按球员导出'**
  String get playerExport;

  /// No description provided for @optional.
  ///
  /// In zh, this message translates to:
  /// **'可选'**
  String get optional;

  /// No description provided for @outputMode.
  ///
  /// In zh, this message translates to:
  /// **'输出方式'**
  String get outputMode;

  /// No description provided for @mobileExportDescription.
  ///
  /// In zh, this message translates to:
  /// **'当前移动端使用原视频分别导出，保留原始音频。'**
  String get mobileExportDescription;

  /// No description provided for @exportAllSeparately.
  ///
  /// In zh, this message translates to:
  /// **'分别导出全部'**
  String get exportAllSeparately;

  /// No description provided for @mergeAllIncluded.
  ///
  /// In zh, this message translates to:
  /// **'合并导出全部保留片段'**
  String get mergeAllIncluded;

  /// No description provided for @mergePlayerClips.
  ///
  /// In zh, this message translates to:
  /// **'合并导出 {player} 的片段'**
  String mergePlayerClips(Object player);

  /// No description provided for @exportedClips.
  ///
  /// In zh, this message translates to:
  /// **'已导出 {count} 个片段'**
  String exportedClips(Object count);

  /// No description provided for @configureProject.
  ///
  /// In zh, this message translates to:
  /// **'配置分析项目'**
  String get configureProject;

  /// No description provided for @confirmProjectSteps.
  ///
  /// In zh, this message translates to:
  /// **'按步骤确认视频、分析范围和篮筐检测区域，最后再开始分析。'**
  String get confirmProjectSteps;

  /// No description provided for @chooseVideoLastStep.
  ///
  /// In zh, this message translates to:
  /// **'先选择一段固定机位视频，系统会在最后一步统一应用配置。'**
  String get chooseVideoLastStep;

  /// No description provided for @relinkVideo.
  ///
  /// In zh, this message translates to:
  /// **'重新定位视频'**
  String get relinkVideo;

  /// No description provided for @replaceVideo.
  ///
  /// In zh, this message translates to:
  /// **'更换视频'**
  String get replaceVideo;

  /// No description provided for @nextStep.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get nextStep;

  /// No description provided for @confirmAndStartAnalysis.
  ///
  /// In zh, this message translates to:
  /// **'确认配置并开始分析'**
  String get confirmAndStartAnalysis;

  /// No description provided for @detectRegionStep.
  ///
  /// In zh, this message translates to:
  /// **'检测区域'**
  String get detectRegionStep;

  /// No description provided for @confirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get confirm;

  /// No description provided for @rangeEditorHint.
  ///
  /// In zh, this message translates to:
  /// **'播放片段会在范围内循环；拖动两端、拖到边缘可继续延长，或用 I / O 把当前位置设为开始 / 结束。原视频不会被修改。'**
  String get rangeEditorHint;

  /// No description provided for @rangeManualHint.
  ///
  /// In zh, this message translates to:
  /// **'已定位到原视频当前时间。用 I / O 设定开始和结束后加入候选。'**
  String get rangeManualHint;

  /// No description provided for @rangePlayClip.
  ///
  /// In zh, this message translates to:
  /// **'播放片段（Space）'**
  String get rangePlayClip;

  /// No description provided for @rangePause.
  ///
  /// In zh, this message translates to:
  /// **'暂停（Space）'**
  String get rangePause;

  /// No description provided for @rangePreviewEnding.
  ///
  /// In zh, this message translates to:
  /// **'预览结尾'**
  String get rangePreviewEnding;

  /// No description provided for @rangeStatusInside.
  ///
  /// In zh, this message translates to:
  /// **'范围内'**
  String get rangeStatusInside;

  /// No description provided for @rangeStatusBefore.
  ///
  /// In zh, this message translates to:
  /// **'范围前'**
  String get rangeStatusBefore;

  /// No description provided for @rangeStatusAfter.
  ///
  /// In zh, this message translates to:
  /// **'范围后'**
  String get rangeStatusAfter;

  /// No description provided for @rangePosition.
  ///
  /// In zh, this message translates to:
  /// **'当前位置 {time}'**
  String rangePosition(String time);

  /// No description provided for @rangeSummary.
  ///
  /// In zh, this message translates to:
  /// **'片段 {start} – {end} · {duration}'**
  String rangeSummary(String start, String end, String duration);

  /// No description provided for @rangeSetStart.
  ///
  /// In zh, this message translates to:
  /// **'设为开始（I）'**
  String get rangeSetStart;

  /// No description provided for @rangeSetEnd.
  ///
  /// In zh, this message translates to:
  /// **'设为结束（O）'**
  String get rangeSetEnd;

  /// No description provided for @rangeExtendStart.
  ///
  /// In zh, this message translates to:
  /// **'开头 −2 秒'**
  String get rangeExtendStart;

  /// No description provided for @rangeExtendEnd.
  ///
  /// In zh, this message translates to:
  /// **'结尾 +2 秒'**
  String get rangeExtendEnd;

  /// No description provided for @rangeExtendBoth.
  ///
  /// In zh, this message translates to:
  /// **'前后各 +2 秒'**
  String get rangeExtendBoth;

  /// No description provided for @rangeLegendEvent.
  ///
  /// In zh, this message translates to:
  /// **'进球时刻'**
  String get rangeLegendEvent;

  /// No description provided for @rangeLegendOriginal.
  ///
  /// In zh, this message translates to:
  /// **'原范围'**
  String get rangeLegendOriginal;

  /// No description provided for @rangeTimelineLabel.
  ///
  /// In zh, this message translates to:
  /// **'片段时间轴'**
  String get rangeTimelineLabel;

  /// No description provided for @reviewStatusAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get reviewStatusAll;

  /// No description provided for @reviewStatusKept.
  ///
  /// In zh, this message translates to:
  /// **'保留'**
  String get reviewStatusKept;

  /// No description provided for @reviewStatusExcluded.
  ///
  /// In zh, this message translates to:
  /// **'排除'**
  String get reviewStatusExcluded;

  /// No description provided for @reviewStatusFilter.
  ///
  /// In zh, this message translates to:
  /// **'按保留／排除筛选'**
  String get reviewStatusFilter;

  /// No description provided for @reviewClearFilters.
  ///
  /// In zh, this message translates to:
  /// **'清除筛选'**
  String get reviewClearFilters;

  /// No description provided for @reviewMoreActions.
  ///
  /// In zh, this message translates to:
  /// **'更多操作'**
  String get reviewMoreActions;

  /// No description provided for @reviewAddMissed.
  ///
  /// In zh, this message translates to:
  /// **'补漏片段'**
  String get reviewAddMissed;

  /// No description provided for @reviewKeepAction.
  ///
  /// In zh, this message translates to:
  /// **'保留'**
  String get reviewKeepAction;

  /// No description provided for @reviewExcludeAction.
  ///
  /// In zh, this message translates to:
  /// **'排除'**
  String get reviewExcludeAction;

  /// No description provided for @reviewWillExport.
  ///
  /// In zh, this message translates to:
  /// **'会导出'**
  String get reviewWillExport;

  /// No description provided for @reviewWillNotExport.
  ///
  /// In zh, this message translates to:
  /// **'不会导出'**
  String get reviewWillNotExport;

  /// No description provided for @reviewUndoLast.
  ///
  /// In zh, this message translates to:
  /// **'撤销上一步'**
  String get reviewUndoLast;

  /// No description provided for @reviewAdjustRange.
  ///
  /// In zh, this message translates to:
  /// **'调整范围'**
  String get reviewAdjustRange;

  /// No description provided for @reviewNote.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get reviewNote;

  /// No description provided for @reviewScores.
  ///
  /// In zh, this message translates to:
  /// **'评分'**
  String get reviewScores;

  /// No description provided for @reviewSignals.
  ///
  /// In zh, this message translates to:
  /// **'信号'**
  String get reviewSignals;

  /// No description provided for @reviewCurrentClip.
  ///
  /// In zh, this message translates to:
  /// **'当前片段'**
  String get reviewCurrentClip;

  /// No description provided for @reviewAnalysisDetails.
  ///
  /// In zh, this message translates to:
  /// **'分析详情'**
  String get reviewAnalysisDetails;

  /// No description provided for @exportOutputMode.
  ///
  /// In zh, this message translates to:
  /// **'输出方式'**
  String get exportOutputMode;

  /// No description provided for @exportMergeTitle.
  ///
  /// In zh, this message translates to:
  /// **'合并成一个视频'**
  String get exportMergeTitle;

  /// No description provided for @exportMergeDescription.
  ///
  /// In zh, this message translates to:
  /// **'按时间顺序拼接为一个 MP4，适合直接分享。'**
  String get exportMergeDescription;

  /// No description provided for @exportSeparateTitle.
  ///
  /// In zh, this message translates to:
  /// **'每个片段单独导出'**
  String get exportSeparateTitle;

  /// No description provided for @exportSeparateDescription.
  ///
  /// In zh, this message translates to:
  /// **'每段一个文件，放进同一个文件夹，适合二次剪辑。'**
  String get exportSeparateDescription;

  /// No description provided for @exportStartButton.
  ///
  /// In zh, this message translates to:
  /// **'导出 {count} 个片段'**
  String exportStartButton(int count);

  /// No description provided for @exportStartHint.
  ///
  /// In zh, this message translates to:
  /// **'下一步选择保存位置，已排除的片段不会进入输出。'**
  String get exportStartHint;

  /// No description provided for @exportClipCount.
  ///
  /// In zh, this message translates to:
  /// **'片段'**
  String get exportClipCount;

  /// No description provided for @exportScopeHint.
  ///
  /// In zh, this message translates to:
  /// **'可多选球员'**
  String get exportScopeHint;

  /// No description provided for @exportRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近导出'**
  String get exportRecent;

  /// No description provided for @exportRunningTitle.
  ///
  /// In zh, this message translates to:
  /// **'正在导出'**
  String get exportRunningTitle;

  /// No description provided for @homeContinueTitle.
  ///
  /// In zh, this message translates to:
  /// **'继续上次'**
  String get homeContinueTitle;

  /// No description provided for @homeContinueReview.
  ///
  /// In zh, this message translates to:
  /// **'继续审核'**
  String get homeContinueReview;

  /// No description provided for @homeContinueSetup.
  ///
  /// In zh, this message translates to:
  /// **'继续配置'**
  String get homeContinueSetup;

  /// No description provided for @homeNoCurrentProject.
  ///
  /// In zh, this message translates to:
  /// **'还没有打开的项目'**
  String get homeNoCurrentProject;

  /// No description provided for @homeNoCurrentProjectDescription.
  ///
  /// In zh, this message translates to:
  /// **'新建项目，或从下方最近项目中打开一个继续。'**
  String get homeNoCurrentProjectDescription;

  /// No description provided for @homeSupportedFormats.
  ///
  /// In zh, this message translates to:
  /// **'MP4 · MOV · M4V · AVI · MKV · 原始视频不会被修改'**
  String get homeSupportedFormats;

  /// No description provided for @homeCandidates.
  ///
  /// In zh, this message translates to:
  /// **'候选'**
  String get homeCandidates;

  /// No description provided for @homeKept.
  ///
  /// In zh, this message translates to:
  /// **'保留'**
  String get homeKept;

  /// No description provided for @homeExcluded.
  ///
  /// In zh, this message translates to:
  /// **'排除'**
  String get homeExcluded;

  /// No description provided for @homeStatusPending.
  ///
  /// In zh, this message translates to:
  /// **'待审核'**
  String get homeStatusPending;

  /// No description provided for @homeStatusExported.
  ///
  /// In zh, this message translates to:
  /// **'已导出'**
  String get homeStatusExported;

  /// No description provided for @homeStatusEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无候选'**
  String get homeStatusEmpty;

  /// No description provided for @homeStatusMissingVideo.
  ///
  /// In zh, this message translates to:
  /// **'视频缺失'**
  String get homeStatusMissingVideo;

  /// No description provided for @homeStatusAnalyzing.
  ///
  /// In zh, this message translates to:
  /// **'分析中'**
  String get homeStatusAnalyzing;

  /// No description provided for @homeProjectActions.
  ///
  /// In zh, this message translates to:
  /// **'项目操作'**
  String get homeProjectActions;

  /// No description provided for @importNextTo.
  ///
  /// In zh, this message translates to:
  /// **'下一步：{step}'**
  String importNextTo(String step);

  /// No description provided for @importConfirmStep.
  ///
  /// In zh, this message translates to:
  /// **'确认并分析'**
  String get importConfirmStep;

  /// No description provided for @importReplacesCandidates.
  ///
  /// In zh, this message translates to:
  /// **'已有候选会被本次结果替换'**
  String get importReplacesCandidates;

  /// No description provided for @importRangeAnalyzed.
  ///
  /// In zh, this message translates to:
  /// **'分析时长'**
  String get importRangeAnalyzed;

  /// No description provided for @importRangeExcluded.
  ///
  /// In zh, this message translates to:
  /// **'已排除'**
  String get importRangeExcluded;

  /// No description provided for @importRangeCoverage.
  ///
  /// In zh, this message translates to:
  /// **'全片 {total} · 分析其中 {percent}%'**
  String importRangeCoverage(String total, int percent);

  /// No description provided for @importSetStart.
  ///
  /// In zh, this message translates to:
  /// **'设为起点'**
  String get importSetStart;

  /// No description provided for @importSetEnd.
  ///
  /// In zh, this message translates to:
  /// **'设为终点'**
  String get importSetEnd;

  /// No description provided for @importSummaryTitle.
  ///
  /// In zh, this message translates to:
  /// **'配置摘要'**
  String get importSummaryTitle;

  /// No description provided for @importEdit.
  ///
  /// In zh, this message translates to:
  /// **'修改'**
  String get importEdit;

  /// No description provided for @importAnalysisMode.
  ///
  /// In zh, this message translates to:
  /// **'分析模式'**
  String get importAnalysisMode;

  /// No description provided for @importStandardDescription.
  ///
  /// In zh, this message translates to:
  /// **'完整检测，漏检更少。'**
  String get importStandardDescription;

  /// No description provided for @importFastDescription.
  ///
  /// In zh, this message translates to:
  /// **'使用低规格代理，更快，但可能漏检少量片段。'**
  String get importFastDescription;

  /// No description provided for @importRecommended.
  ///
  /// In zh, this message translates to:
  /// **'推荐'**
  String get importRecommended;

  /// No description provided for @importClipLengthHint.
  ///
  /// In zh, this message translates to:
  /// **'审核时仍可单独调整每个片段'**
  String get importClipLengthHint;

  /// No description provided for @importClipTotal.
  ///
  /// In zh, this message translates to:
  /// **'每段 {seconds} 秒'**
  String importClipTotal(int seconds);

  /// No description provided for @importEstimate.
  ///
  /// In zh, this message translates to:
  /// **'预计耗时 {estimate} · 实际受视频编码、磁盘和设备负载影响'**
  String importEstimate(String estimate);

  /// No description provided for @reviewProgress.
  ///
  /// In zh, this message translates to:
  /// **'已审核 {done} / {total}'**
  String reviewProgress(int done, int total);

  /// No description provided for @reviewUnreviewed.
  ///
  /// In zh, this message translates to:
  /// **'未审核'**
  String get reviewUnreviewed;

  /// No description provided for @homeDropHint.
  ///
  /// In zh, this message translates to:
  /// **'也可以把一段或多段视频拖到这里'**
  String get homeDropHint;

  /// No description provided for @homeDropActive.
  ///
  /// In zh, this message translates to:
  /// **'松开即可新建项目'**
  String get homeDropActive;

  /// No description provided for @homeDropUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'不支持这个文件，请拖入 MP4、MOV、M4V、AVI 或 MKV 视频'**
  String get homeDropUnsupported;
}

class _BheLocalizationsDelegate
    extends LocalizationsDelegate<BheLocalizations> {
  const _BheLocalizationsDelegate();

  @override
  Future<BheLocalizations> load(Locale locale) {
    return SynchronousFuture<BheLocalizations>(lookupBheLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_BheLocalizationsDelegate old) => false;
}

BheLocalizations lookupBheLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return BheLocalizationsEn();
    case 'zh':
      return BheLocalizationsZh();
  }

  throw FlutterError(
    'BheLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
