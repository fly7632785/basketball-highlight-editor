// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'bhe_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class BheLocalizationsEn extends BheLocalizations {
  BheLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'BHE';

  @override
  String get navProject => 'Project';

  @override
  String get navImport => 'Import';

  @override
  String get navReview => 'Review';

  @override
  String get navExport => 'Export';

  @override
  String get newProject => 'New project';

  @override
  String get openPackage => 'Open project package';

  @override
  String get deleteProject => 'Delete current project';

  @override
  String get more => 'More';

  @override
  String get feedback => 'Feedback';

  @override
  String get feedbackMailClientMissing =>
      'No mail client is available. Please contact the feedback email manually.';

  @override
  String get about => 'About BHE';

  @override
  String get backToProject => 'Back to project';

  @override
  String get localProcessing => 'Processed locally';

  @override
  String get switchTheme => 'Switch theme';

  @override
  String get switchLanguage => 'Switch language';

  @override
  String get languageChinese => '简体中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get taskInProgress => 'Task in progress';

  @override
  String get confirmExit => 'Exit BHE?';

  @override
  String get cancelTaskAndExit => 'Cancel task and exit';

  @override
  String get exitApp => 'Exit';

  @override
  String get returnAction => 'Back';

  @override
  String get confirmCloseProject => 'Close current project?';

  @override
  String get closeProjectBusyDescription =>
      'The current task will be cancelled first. Project data and the source video will not be deleted.';

  @override
  String get closeProjectDescription =>
      'Project data and the source video will be kept and can be reopened from the project list.';

  @override
  String get cancelTaskAndClose => 'Cancel task and close';

  @override
  String get closeProject => 'Close project';

  @override
  String get engineReady => 'Engine ready';

  @override
  String get engineNotStarted => 'Engine not started';

  @override
  String get waitingEngine => 'Waiting for Engine';

  @override
  String get engineError => 'Engine error';

  @override
  String get collapseSidebar => 'Collapse sidebar';

  @override
  String get expandSidebar => 'Expand sidebar';

  @override
  String get exitBusyDescription =>
      'A task is still running and must be cancelled before exiting.';

  @override
  String get exitDescription =>
      'Close the app? Local project data will not be deleted.';

  @override
  String get pressBackAgainToExit => 'Press back again to exit BHE';

  @override
  String get homeHeadline => 'Turn the whole game into your highlights.';

  @override
  String get homeSubtitle =>
      'Import a fixed-camera video, find scoring candidates locally, remove false positives, and export a highlight reel. Processing stays on this device; the source video is not copied or uploaded.';

  @override
  String get startFromVideo => 'Start from video';

  @override
  String get openProject => 'Open project';

  @override
  String get startFromVideoDescription =>
      'Choose a fixed-camera recording. BHE first locates the hoop, then creates scoring candidates for review and export.';

  @override
  String get currentProject => 'Current project';

  @override
  String get includedCount => 'Included';

  @override
  String get excludedCount => 'Excluded';

  @override
  String get videoDuration => 'Video duration';

  @override
  String get localDatabaseNote => 'Local SQLite · source video is not copied';

  @override
  String get recentProjects => 'Recent projects';

  @override
  String get refreshRecentProjects => 'Refresh recent projects';

  @override
  String get workflow => 'Workflow';

  @override
  String get deleteProjectQuestion => 'Delete project?';

  @override
  String deleteProjectDescription(Object name) {
    return 'This deletes the project database, analysis cache, and exports for “$name”. The source video will not be deleted.';
  }

  @override
  String get noProjects => 'No projects yet';

  @override
  String get recentProjectsLoadFailed => 'Could not load recent projects';

  @override
  String get noProjectsDescription =>
      'Create a project to see its analysis records and export history here.';

  @override
  String get importVideoStep => 'Import video';

  @override
  String get roiStep => 'Set ROI';

  @override
  String get analysisStep => 'Analyze';

  @override
  String get reviewStep => 'Review candidates';

  @override
  String get exportHighlightsStep => 'Export highlights';

  @override
  String get exportHighlights => 'Export highlights';

  @override
  String get exportDescription =>
      'Analysis results are included by default. Export only excludes clips you reject.';

  @override
  String get totalDuration => 'Total duration';

  @override
  String get outputCodec => 'Output codec';

  @override
  String get processingMethod => 'Processing';

  @override
  String get exportScope => 'Export scope';

  @override
  String get allPlayers => 'All players';

  @override
  String get unassigned => 'Unassigned';

  @override
  String get currentFilter => 'Current filter';

  @override
  String get cancelExport => 'Cancel export';

  @override
  String get analysisStillRunning =>
      'The video is still being analyzed. New candidates can be exported when analysis finishes.';

  @override
  String get fastAnalysisRisk =>
      'This result came from fast analysis and may miss clips. Use standard analysis for a more complete result.';

  @override
  String get dismissHint => 'Dismiss hint';

  @override
  String get exportInterrupted =>
      'The previous export was interrupted. You can export again with the same settings.';

  @override
  String get projectWorkspace => 'Project workspace';

  @override
  String get startVideoProject => 'Start a video project';

  @override
  String get selectVideo => 'Choose video';

  @override
  String get localCompleteDescription => 'Analyze, review, and export locally.';

  @override
  String get configureAnalysisDescription =>
      'Configure the analysis regions to start detection.';

  @override
  String get prepareVideo => 'Preparing video';

  @override
  String get selectMatchVideo => 'Choose a game video';

  @override
  String get mobileCandidateDescription =>
      'BHE creates candidate clips locally for quick review.';

  @override
  String get analysisConfig => 'Analysis settings';

  @override
  String get autoSave => 'Auto-saved';

  @override
  String get analysisQuality => 'Analysis quality';

  @override
  String get clipDuration => 'Clip duration';

  @override
  String get roiZones => 'Shot and net regions';

  @override
  String get notSet => 'Not set';

  @override
  String get roiConfigured => 'Set; hoop calibration is saved separately';

  @override
  String get analysisRange => 'Analysis range';

  @override
  String get noCandidatesAdvice =>
      'No candidate clips were found. Check the detection regions or analysis range and try again.';

  @override
  String get analysisInterrupted =>
      'The previous analysis did not finish. You can start it again.';

  @override
  String get startAnalysis => 'Start analysis';

  @override
  String get redoAnalysis => 'Analyze again';

  @override
  String reviewCount(Object count) {
    return 'Review $count';
  }

  @override
  String lastAnalysisDuration(Object duration) {
    return 'Last analysis took $duration';
  }

  @override
  String get startAnalysisTitle => 'Start analysis';

  @override
  String get foregroundAnalysisWarning =>
      'Keep BHE in the foreground and keep the screen on during analysis. Locking the screen or switching apps may slow down or pause analysis.';

  @override
  String get start => 'Start';

  @override
  String get processingValue => 'Hardware encoding first, software fallback';

  @override
  String standardQuality(Object fps, Object size) {
    return 'Standard · $size input / ${fps}fps';
  }

  @override
  String highQuality(Object fps, Object size) {
    return 'High quality · $size input / ${fps}fps';
  }

  @override
  String get analysisInProgress => 'Analyzing video';

  @override
  String get checkingVideo => 'Check video';

  @override
  String get showTrajectory => 'Show trajectory';

  @override
  String get hideTrajectory => 'Hide trajectory';

  @override
  String get shortcuts => 'Shortcuts';

  @override
  String get moreReviewActions => 'More review actions';

  @override
  String get editClipRange => 'Adjust clip range';

  @override
  String get viewEvidence => 'View evidence';

  @override
  String get exportIncluded => 'Export included clips';

  @override
  String get replay => 'Replay';

  @override
  String get openAutoReplay => 'Enable auto replay';

  @override
  String get closeAutoReplay => 'Disable auto replay';

  @override
  String get playbackSpeed => 'Playback speed';

  @override
  String get reviewMode => 'Review';

  @override
  String get originalVideo => 'Original video';

  @override
  String currentTime(Object time) {
    return 'Current $time';
  }

  @override
  String clipTime(Object end, Object start) {
    return 'Clip $start — $end';
  }

  @override
  String fullVideoTime(Object duration) {
    return 'Full video $duration';
  }

  @override
  String get include => 'Include';

  @override
  String get exclude => 'Exclude';

  @override
  String get statusConfirmed => 'Confirmed';

  @override
  String get statusPending => 'Needs review';

  @override
  String candidateCount(Object count) {
    return 'Candidates $count';
  }

  @override
  String get addManualCandidate => 'Add manually';

  @override
  String get reviewComplete => 'Review complete';

  @override
  String reviewCompleteDescription(Object count) {
    return 'Processed $count candidate clips. You can continue to export.';
  }

  @override
  String get laterExport => 'Export later';

  @override
  String get goExport => 'Go to export';

  @override
  String get productDescription =>
      'Identify shot candidates from fixed-camera video and quickly export personal or full-game highlights after review.';

  @override
  String get feedbackEmail => 'Feedback email';

  @override
  String get githubComingSoon => 'Coming soon';

  @override
  String get sendFeedback => 'Send feedback';

  @override
  String projectStats(Object candidates, Object duration, Object included) {
    return '$included included · $candidates candidates · $duration';
  }

  @override
  String filterStats(Object count, Object duration) {
    return '$count clips · $duration';
  }

  @override
  String get analysisLocalSaved =>
      'Analysis runs locally and saves the result automatically when complete.';

  @override
  String elapsed(Object duration) {
    return 'Elapsed $duration';
  }

  @override
  String remaining(Object duration) {
    return 'About $duration left';
  }

  @override
  String get prepareLocalAnalysis => 'Preparing local analysis';

  @override
  String processedFrames(Object processed, Object total) {
    return '$processed / $total frames';
  }

  @override
  String get exportPageSubtitle =>
      'Export included clips from the review. Export separately or merge them into one video.';

  @override
  String get keptClips => 'Included clips';

  @override
  String get output => 'Output';

  @override
  String get playerExport => 'Export by player';

  @override
  String get optional => 'Optional';

  @override
  String get outputMode => 'Output mode';

  @override
  String get mobileExportDescription =>
      'Mobile export uses the original video separately and keeps the original audio.';

  @override
  String get exportAllSeparately => 'Export all separately';

  @override
  String get mergeAllIncluded => 'Merge all included clips';

  @override
  String mergePlayerClips(Object player) {
    return 'Merge $player clips';
  }

  @override
  String exportedClips(Object count) {
    return 'Exported $count clips';
  }

  @override
  String get configureProject => 'Configure analysis project';

  @override
  String get confirmProjectSteps =>
      'Confirm the video, analysis range, and hoop detection regions step by step before starting analysis.';

  @override
  String get chooseVideoLastStep =>
      'Choose a fixed-camera video first. Settings will be applied together in the final step.';

  @override
  String get relinkVideo => 'Relink video';

  @override
  String get replaceVideo => 'Replace video';

  @override
  String get nextStep => 'Next';

  @override
  String get confirmAndStartAnalysis => 'Confirm settings and start analysis';

  @override
  String get detectRegionStep => 'Detection region';

  @override
  String get confirm => 'Confirm';

  @override
  String get cancel => 'Cancel';

  @override
  String get close => 'Close';
}
