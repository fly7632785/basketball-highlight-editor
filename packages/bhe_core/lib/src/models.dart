import 'package:meta/meta.dart';

enum CandidateSelection { included, excluded }

enum AnalysisMode { standard, highQuality }

enum AnalysisStage {
  idle,
  validateInput,
  prepareProxy,
  coarseScan,
  generateCandidates,
  refineCandidates,
  persistCandidates,
  completed,
  cancelled,
  failed,
}

@immutable
class VideoInfo {
  const VideoInfo({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.durationMs,
    required this.width,
    required this.height,
    this.sha256,
  });

  final String path;
  final String name;
  final int sizeBytes;
  final int durationMs;
  final int width;
  final int height;
  final String? sha256;

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'size_bytes': sizeBytes,
        'duration_ms': durationMs,
        'width': width,
        'height': height,
        if (sha256 != null) 'sha256': sha256,
      };

  factory VideoInfo.fromJson(Map<String, dynamic> json) => VideoInfo(
        path: json['path'] as String? ?? '',
        name: json['name'] as String? ?? 'video',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        sha256: json['sha256'] as String?,
      );
}

@immutable
class Roi {
  const Roi({required this.left, required this.top, required this.right, required this.bottom});

  final double left;
  final double top;
  final double right;
  final double bottom;

  Map<String, dynamic> toJson() => {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };

  factory Roi.fromJson(Map<String, dynamic> json) => Roi(
        left: (json['left'] as num?)?.toDouble() ?? 0,
        top: (json['top'] as num?)?.toDouble() ?? 0,
        right: (json['right'] as num?)?.toDouble() ?? 1,
        bottom: (json['bottom'] as num?)?.toDouble() ?? 1,
      );
}

@immutable
class Candidate {
  const Candidate({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.eventMs,
    this.confidence = 0,
    this.selection = CandidateSelection.included,
    this.player,
    this.note,
    this.trajectoryScore,
    this.crossingScore,
    this.netMotionScore,
  });

  final String id;
  final int startMs;
  final int endMs;
  final int eventMs;
  final double confidence;
  final CandidateSelection selection;
  final String? player;
  final String? note;
  final double? trajectoryScore;
  final double? crossingScore;
  final double? netMotionScore;

  Candidate copyWith({
    int? startMs,
    int? endMs,
    CandidateSelection? selection,
    String? player,
    bool clearPlayer = false,
    String? note,
    bool clearNote = false,
  }) => Candidate(
        id: id,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        eventMs: eventMs,
        confidence: confidence,
        selection: selection ?? this.selection,
        player: clearPlayer ? null : (player ?? this.player),
        note: clearNote ? null : (note ?? this.note),
        trajectoryScore: trajectoryScore,
        crossingScore: crossingScore,
        netMotionScore: netMotionScore,
      );

  Duration get duration => Duration(milliseconds: endMs - startMs);

  String get displayTime {
    final seconds = eventMs ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'start_ms': startMs,
        'end_ms': endMs,
        'event_ms': eventMs,
        'confidence': confidence,
        'selection': selection.name,
        if (player != null) 'player': player,
        if (note != null) 'note': note,
        if (trajectoryScore != null) 'trajectory_score': trajectoryScore,
        if (crossingScore != null) 'crossing_score': crossingScore,
        if (netMotionScore != null) 'net_motion_score': netMotionScore,
      };

  factory Candidate.fromJson(Map<String, dynamic> json) => Candidate(
        id: json['id'] as String? ?? 'candidate',
        startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
        endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
        eventMs: (json['event_ms'] as num?)?.toInt() ?? 0,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        selection: CandidateSelection.values.firstWhere(
          (value) => value.name == json['selection'],
          orElse: () => CandidateSelection.included,
        ),
        player: json['player'] as String?,
        note: json['note'] as String?,
        trajectoryScore: (json['trajectory_score'] as num?)?.toDouble(),
        crossingScore: (json['crossing_score'] as num?)?.toDouble(),
        netMotionScore: (json['net_motion_score'] as num?)?.toDouble(),
      );
}

@immutable
class ClipSettings {
  const ClipSettings({this.beforeSeconds = 6, this.afterSeconds = 3});

  final int beforeSeconds;
  final int afterSeconds;

  Map<String, dynamic> toJson() => {
        'before_seconds': beforeSeconds,
        'after_seconds': afterSeconds,
      };

  factory ClipSettings.fromJson(Map<String, dynamic> json) => ClipSettings(
        beforeSeconds: (json['before_seconds'] as num?)?.toInt() ?? 6,
        afterSeconds: (json['after_seconds'] as num?)?.toInt() ?? 3,
      );
}

@immutable
class AnalysisSettings {
  const AnalysisSettings({
    this.mode = AnalysisMode.standard,
    this.clip = const ClipSettings(),
    this.startMs = 0,
    this.endMs,
  });

  final AnalysisMode mode;
  final ClipSettings clip;
  final int startMs;
  final int? endMs;

  int get proxyWidth => mode == AnalysisMode.highQuality ? 960 : 640;
  int get proxyHeight => mode == AnalysisMode.highQuality ? 720 : 480;
  double get proxyFps => mode == AnalysisMode.highQuality ? 5 : 3;

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'clip': clip.toJson(),
        'start_ms': startMs,
        if (endMs != null) 'end_ms': endMs,
      };

  factory AnalysisSettings.fromJson(Map<String, dynamic> json) => AnalysisSettings(
        mode: AnalysisMode.values.firstWhere(
          (value) => value.name == json['mode'],
          orElse: () => AnalysisMode.standard,
        ),
        clip: ClipSettings.fromJson((json['clip'] as Map?)?.cast<String, dynamic>() ?? {}),
        startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
        endMs: (json['end_ms'] as num?)?.toInt(),
      );
}

@immutable
class ProjectSnapshot {
  const ProjectSnapshot({
    required this.id,
    required this.name,
    required this.video,
    this.hoopRoi,
    this.netRoi,
    this.settings = const AnalysisSettings(),
    this.candidates = const [],
    this.players = const [],
    this.lastAnalysisDurationMs,
    this.lastAnalysisAt,
    this.lastExportDurationMs,
  });

  final String id;
  final String name;
  final VideoInfo? video;
  final Roi? hoopRoi;
  final Roi? netRoi;
  final AnalysisSettings settings;
  final List<Candidate> candidates;
  final List<String> players;
  final int? lastAnalysisDurationMs;
  final DateTime? lastAnalysisAt;
  final int? lastExportDurationMs;

  int get includedCount => candidates
      .where((candidate) => candidate.selection == CandidateSelection.included)
      .length;

  int get excludedCount => candidates
      .where((candidate) => candidate.selection == CandidateSelection.excluded)
      .length;

  ProjectSnapshot copyWith({
    String? name,
    VideoInfo? video,
    bool clearVideo = false,
    Roi? hoopRoi,
    Roi? netRoi,
    bool clearHoopRoi = false,
    bool clearNetRoi = false,
    AnalysisSettings? settings,
    List<Candidate>? candidates,
    List<String>? players,
    int? lastAnalysisDurationMs,
    DateTime? lastAnalysisAt,
    bool clearLastAnalysis = false,
    int? lastExportDurationMs,
  }) => ProjectSnapshot(
        id: id,
        name: name ?? this.name,
        video: clearVideo ? null : (video ?? this.video),
        hoopRoi: clearHoopRoi ? null : (hoopRoi ?? this.hoopRoi),
        netRoi: clearNetRoi ? null : (netRoi ?? this.netRoi),
        settings: settings ?? this.settings,
        candidates: candidates ?? this.candidates,
        players: players ?? this.players,
        lastAnalysisDurationMs: clearLastAnalysis ? null : (lastAnalysisDurationMs ?? this.lastAnalysisDurationMs),
        lastAnalysisAt: clearLastAnalysis ? null : (lastAnalysisAt ?? this.lastAnalysisAt),
        lastExportDurationMs: lastExportDurationMs ?? this.lastExportDurationMs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (video != null) 'video': video!.toJson(),
        if (hoopRoi != null) 'hoop_roi': hoopRoi!.toJson(),
        if (netRoi != null) 'net_roi': netRoi!.toJson(),
        'settings': settings.toJson(),
        'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
        'players': players,
        if (lastAnalysisDurationMs != null) 'last_analysis_duration_ms': lastAnalysisDurationMs,
        if (lastAnalysisAt != null) 'last_analysis_at': lastAnalysisAt!.toUtc().toIso8601String(),
        if (lastExportDurationMs != null) 'last_export_duration_ms': lastExportDurationMs,
      };

  factory ProjectSnapshot.fromJson(Map<String, dynamic> json) => ProjectSnapshot(
        id: json['id'] as String? ?? 'project',
        name: json['name'] as String? ?? '未命名项目',
        video: _mapValue(json['video'], VideoInfo.fromJson),
        hoopRoi: _mapValue(json['hoop_roi'], Roi.fromJson),
        netRoi: _mapValue(json['net_roi'], Roi.fromJson),
        settings: AnalysisSettings.fromJson(
          (json['settings'] as Map?)?.cast<String, dynamic>() ?? {},
        ),
        candidates: ((json['candidates'] as List?) ?? const [])
            .whereType<Map>()
            .map((item) => Candidate.fromJson(item.cast<String, dynamic>()))
            .toList(),
        players: ((json['players'] as List?) ?? const []).whereType<String>().toList(),
        lastAnalysisDurationMs: (json['last_analysis_duration_ms'] as num?)?.toInt(),
        lastAnalysisAt: DateTime.tryParse(json['last_analysis_at'] as String? ?? ''),
        lastExportDurationMs: (json['last_export_duration_ms'] as num?)?.toInt(),
      );
}

TResult? _mapValue<TResult>(
  Object? value,
  TResult Function(Map<String, dynamic>) transform,
) {
  if (value is! Map) return null;
  return transform(value.cast<String, dynamic>());
}
