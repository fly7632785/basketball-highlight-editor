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
  const Roi({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

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
class EvidencePoint {
  const EvidencePoint({
    required this.timeMs,
    required this.x,
    required this.y,
    this.confidence,
  });

  final int timeMs;
  final double x;
  final double y;
  final double? confidence;

  Map<String, dynamic> toJson() => {
    'time_ms': timeMs,
    'x': x,
    'y': y,
    if (confidence != null) 'confidence': confidence,
  };

  factory EvidencePoint.fromJson(Map<String, dynamic> json) {
    final timeMs = json['time_ms'];
    final timeSeconds = json['time'];
    return EvidencePoint(
      timeMs: timeMs is num
          ? timeMs.round()
          : timeSeconds is num
          ? (timeSeconds * 1000).round()
          : 0,
      x: (json['x'] as num?)?.toDouble() ?? 0,
      y: (json['y'] as num?)?.toDouble() ?? 0,
      confidence: (json['confidence'] as num?)?.toDouble(),
    );
  }
}

@immutable
class Candidate {
  const Candidate({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.eventMs,
    this.defaultStartMs,
    this.defaultEndMs,
    this.rangeEdited = false,
    this.confidence = 0,
    this.selection = CandidateSelection.included,
    this.player,
    this.note,
    this.trajectoryScore,
    this.crossingScore,
    this.netMotionScore,
    this.netSequenceScore,
    this.predictionScore,
    this.compositeScore,
    this.trajectory = const [],
    this.crossingPoint,
    this.predictedLandingPoint,
    this.reason,
    this.verdict,
    this.completeCrossing,
    this.rebound,
    this.evidenceSource,
  });

  final String id;
  final int startMs;
  final int endMs;
  final int eventMs;
  final int? defaultStartMs;
  final int? defaultEndMs;
  final bool rangeEdited;
  final double confidence;
  final CandidateSelection selection;
  final String? player;
  final String? note;
  final double? trajectoryScore;
  final double? crossingScore;
  final double? netMotionScore;
  final double? netSequenceScore;
  final double? predictionScore;
  final double? compositeScore;
  final List<EvidencePoint> trajectory;
  final EvidencePoint? crossingPoint;
  final EvidencePoint? predictedLandingPoint;
  final String? reason;
  final String? verdict;
  final bool? completeCrossing;
  final bool? rebound;
  final String? evidenceSource;

  Candidate copyWith({
    int? startMs,
    int? endMs,
    int? defaultStartMs,
    int? defaultEndMs,
    bool? rangeEdited,
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
    defaultStartMs: defaultStartMs ?? this.defaultStartMs,
    defaultEndMs: defaultEndMs ?? this.defaultEndMs,
    rangeEdited:
        rangeEdited ??
        ((startMs != null || endMs != null) ? true : this.rangeEdited),
    confidence: confidence,
    selection: selection ?? this.selection,
    player: clearPlayer ? null : (player ?? this.player),
    note: clearNote ? null : (note ?? this.note),
    trajectoryScore: trajectoryScore,
    crossingScore: crossingScore,
    netMotionScore: netMotionScore,
    netSequenceScore: netSequenceScore,
    predictionScore: predictionScore,
    compositeScore: compositeScore,
    trajectory: trajectory,
    crossingPoint: crossingPoint,
    predictedLandingPoint: predictedLandingPoint,
    reason: reason,
    verdict: verdict,
    completeCrossing: completeCrossing,
    rebound: rebound,
    evidenceSource: evidenceSource,
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
    if (defaultStartMs != null) 'default_start_ms': defaultStartMs,
    if (defaultEndMs != null) 'default_end_ms': defaultEndMs,
    if (rangeEdited) 'range_edited': true,
    'confidence': confidence,
    'selection': selection.name,
    if (player != null) 'player': player,
    if (note != null) 'note': note,
    if (trajectoryScore != null) 'trajectory_score': trajectoryScore,
    if (crossingScore != null) 'crossing_score': crossingScore,
    if (netMotionScore != null) 'net_motion_score': netMotionScore,
    if (netSequenceScore != null) 'net_sequence_score': netSequenceScore,
    if (predictionScore != null) 'prediction_score': predictionScore,
    if (compositeScore != null) 'composite_score': compositeScore,
    if (trajectory.isNotEmpty)
      'trajectory': trajectory.map((point) => point.toJson()).toList(),
    if (crossingPoint != null) 'crossing': crossingPoint!.toJson(),
    if (predictedLandingPoint != null)
      'prediction': predictedLandingPoint!.toJson(),
    if (reason != null) 'reason': reason,
    if (verdict != null) 'verdict': verdict,
    if (completeCrossing != null) 'complete_crossing': completeCrossing,
    if (rebound != null) 'rebound': rebound,
    if (evidenceSource != null) 'evidence_source': evidenceSource,
  };

  factory Candidate.fromJson(Map<String, dynamic> json) {
    final evidence = json['evidence'] is Map
        ? (json['evidence'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final overlay = json['overlay'] is Map
        ? (json['overlay'] as Map).cast<String, dynamic>()
        : evidence['overlay'] is Map
        ? (evidence['overlay'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final trajectoryValue =
        json['trajectory'] ?? overlay['trajectory'] ?? evidence['trajectory'];
    final crossingValue =
        json['crossing'] ?? overlay['crossing'] ?? evidence['crossing'];
    final predictionValue =
        json['prediction'] ?? overlay['prediction'] ?? evidence['prediction'];
    final suggestion = evidence['review_reason_suggestion'];
    final reasonValue =
        json['reason'] ?? (suggestion is Map ? suggestion['primary'] : null);
    final startMs = _intValue(json['start_ms'] ?? json['review_start_ms']);
    final endMs = _intValue(json['end_ms'] ?? json['review_end_ms']);
    final defaultStartMs = json['default_start_ms'] is num
        ? _intValue(json['default_start_ms'])
        : startMs;
    final defaultEndMs = json['default_end_ms'] is num
        ? _intValue(json['default_end_ms'])
        : endMs;
    return Candidate(
      id: json['id'] as String? ?? 'candidate',
      startMs: startMs,
      endMs: endMs,
      eventMs: _intValue(json['event_ms'] ?? json['event_time_ms']),
      defaultStartMs: defaultStartMs,
      defaultEndMs: defaultEndMs,
      rangeEdited:
          json['range_edited'] == true ||
          startMs != defaultStartMs ||
          endMs != defaultEndMs,
      confidence: _scoreValue(json['confidence']),
      selection: CandidateSelection.values.firstWhere(
        (value) => value.name == json['selection'],
        orElse: () => CandidateSelection.included,
      ),
      player: json['player'] as String?,
      note: json['note'] as String?,
      trajectoryScore: _scoreValueOrNull(
        json['trajectory_score'] ??
            (json['trajectory'] is Map
                ? (json['trajectory'] as Map)['trajectory_score']
                : null),
      ),
      crossingScore: _scoreValueOrNull(json['crossing_score']),
      netMotionScore: _scoreValueOrNull(
        json['net_motion_score'] ??
            (json['signals'] is Map
                ? (json['signals'] as Map)['net_score']
                : null),
      ),
      netSequenceScore: _scoreValueOrNull(
        json['net_sequence_score'] ??
            (json['signals'] is Map
                ? (json['signals'] as Map)['net_sequence_score']
                : null),
      ),
      predictionScore: _scoreValueOrNull(json['prediction_score']),
      compositeScore: _scoreValueOrNull(json['composite_score']),
      trajectory: _pointList(trajectoryValue),
      crossingPoint: _pointValue(crossingValue),
      predictedLandingPoint: _pointValue(predictionValue),
      reason: reasonValue as String? ?? evidence['reason'] as String?,
      verdict: json['verdict'] as String? ?? evidence['verdict'] as String?,
      completeCrossing: _boolValue(
        json['complete_crossing'] ?? evidence['complete_crossing'],
      ),
      rebound: _boolValue(json['rebound'] ?? evidence['rebound']),
      evidenceSource:
          json['evidence_source'] as String? ??
          evidence['analysis_source'] as String?,
    );
  }
}

int _intValue(Object? value) => value is num ? value.toInt() : 0;

double _scoreValue(Object? value) => _scoreValueOrNull(value) ?? 0;

double? _scoreValueOrNull(Object? value) {
  if (value is num) return value.toDouble();
  if (value is! String) return null;
  return switch (value.toLowerCase()) {
    'high' => .85,
    'medium' => .6,
    'low' => .3,
    _ => double.tryParse(value),
  };
}

bool? _boolValue(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    return switch (value.toLowerCase()) {
      'true' || 'yes' || 'made' => true,
      'false' || 'no' || 'missed' => false,
      _ => null,
    };
  }
  return null;
}

EvidencePoint? _pointValue(Object? value) {
  if (value is! Map) return null;
  return EvidencePoint.fromJson(value.cast<String, dynamic>());
}

List<EvidencePoint> _pointList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => EvidencePoint.fromJson(item.cast<String, dynamic>()))
      .toList();
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

  factory AnalysisSettings.fromJson(Map<String, dynamic> json) =>
      AnalysisSettings(
        mode: AnalysisMode.values.firstWhere(
          (value) => value.name == json['mode'],
          orElse: () => AnalysisMode.standard,
        ),
        clip: ClipSettings.fromJson(
          (json['clip'] as Map?)?.cast<String, dynamic>() ?? {},
        ),
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
    this.lastAnalysisStatus,
    this.lastAnalysisProgressPercent,
    this.lastAnalysisMessage,
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
  final String? lastAnalysisStatus;
  final int? lastAnalysisProgressPercent;
  final String? lastAnalysisMessage;
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
    String? lastAnalysisStatus,
    int? lastAnalysisProgressPercent,
    String? lastAnalysisMessage,
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
    lastAnalysisDurationMs: clearLastAnalysis
        ? null
        : (lastAnalysisDurationMs ?? this.lastAnalysisDurationMs),
    lastAnalysisAt: clearLastAnalysis
        ? null
        : (lastAnalysisAt ?? this.lastAnalysisAt),
    lastAnalysisStatus: clearLastAnalysis
        ? null
        : (lastAnalysisStatus ?? this.lastAnalysisStatus),
    lastAnalysisProgressPercent: clearLastAnalysis
        ? null
        : (lastAnalysisProgressPercent ?? this.lastAnalysisProgressPercent),
    lastAnalysisMessage: clearLastAnalysis
        ? null
        : (lastAnalysisMessage ?? this.lastAnalysisMessage),
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
    if (lastAnalysisDurationMs != null)
      'last_analysis_duration_ms': lastAnalysisDurationMs,
    if (lastAnalysisAt != null)
      'last_analysis_at': lastAnalysisAt!.toUtc().toIso8601String(),
    if (lastAnalysisStatus != null) 'last_analysis_status': lastAnalysisStatus,
    if (lastAnalysisProgressPercent != null)
      'last_analysis_progress_percent': lastAnalysisProgressPercent,
    if (lastAnalysisMessage != null)
      'last_analysis_message': lastAnalysisMessage,
    if (lastExportDurationMs != null)
      'last_export_duration_ms': lastExportDurationMs,
  };

  factory ProjectSnapshot.fromJson(Map<String, dynamic> json) =>
      ProjectSnapshot(
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
        players: ((json['players'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        lastAnalysisDurationMs: (json['last_analysis_duration_ms'] as num?)
            ?.toInt(),
        lastAnalysisAt: DateTime.tryParse(
          json['last_analysis_at'] as String? ?? '',
        ),
        lastAnalysisStatus: json['last_analysis_status'] as String?,
        lastAnalysisProgressPercent:
            (json['last_analysis_progress_percent'] as num?)?.toInt(),
        lastAnalysisMessage: json['last_analysis_message'] as String?,
        lastExportDurationMs: (json['last_export_duration_ms'] as num?)
            ?.toInt(),
      );
}

TResult? _mapValue<TResult>(
  Object? value,
  TResult Function(Map<String, dynamic>) transform,
) {
  if (value is! Map) return null;
  return transform(value.cast<String, dynamic>());
}
