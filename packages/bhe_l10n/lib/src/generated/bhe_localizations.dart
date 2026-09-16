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

  /// No description provided for @startFromVideo.
  ///
  /// In zh, this message translates to:
  /// **'从视频开始'**
  String get startFromVideo;

  /// No description provided for @openProject.
  ///
  /// In zh, this message translates to:
  /// **'打开项目'**
  String get openProject;

  /// No description provided for @startFromVideoDescription.
  ///
  /// In zh, this message translates to:
  /// **'选择一段固定机位录像，系统会优先自动定位篮筐，随后生成候选进球片段供你审核与导出。'**
  String get startFromVideoDescription;

  /// No description provided for @currentProject.
  ///
  /// In zh, this message translates to:
  /// **'当前项目'**
  String get currentProject;

  /// No description provided for @includedCount.
  ///
  /// In zh, this message translates to:
  /// **'当前保留'**
  String get includedCount;

  /// No description provided for @excludedCount.
  ///
  /// In zh, this message translates to:
  /// **'已排除'**
  String get excludedCount;

  /// No description provided for @videoDuration.
  ///
  /// In zh, this message translates to:
  /// **'视频时长'**
  String get videoDuration;

  /// No description provided for @localDatabaseNote.
  ///
  /// In zh, this message translates to:
  /// **'本地 SQLite · 原始视频不复制'**
  String get localDatabaseNote;

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

  /// No description provided for @workflow.
  ///
  /// In zh, this message translates to:
  /// **'工作流'**
  String get workflow;

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

  /// No description provided for @importVideoStep.
  ///
  /// In zh, this message translates to:
  /// **'导入视频'**
  String get importVideoStep;

  /// No description provided for @roiStep.
  ///
  /// In zh, this message translates to:
  /// **'框选 ROI'**
  String get roiStep;

  /// No description provided for @analysisStep.
  ///
  /// In zh, this message translates to:
  /// **'分析扫描'**
  String get analysisStep;

  /// No description provided for @reviewStep.
  ///
  /// In zh, this message translates to:
  /// **'审核候选'**
  String get reviewStep;

  /// No description provided for @exportHighlightsStep.
  ///
  /// In zh, this message translates to:
  /// **'导出集锦'**
  String get exportHighlightsStep;

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
