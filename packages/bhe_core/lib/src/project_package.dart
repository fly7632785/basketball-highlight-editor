import 'dart:convert';

import 'models.dart';

class ProjectPackageCodec {
  const ProjectPackageCodec();

  String encode(ProjectSnapshot project) {
    final manifest = _manifest(project);
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'bhe-project',
      'version': 2,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'project_id': project.id,
      'project_name': project.name,
      'manifest': manifest,
      ...manifest,
    });
  }

  ProjectSnapshot decode(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! Map) throw const FormatException('项目包格式无效');
    if (decoded['format'] != 'bhe-project')
      throw const FormatException('不是 BHE 项目包');
    final version = (decoded['version'] as num?)?.toInt() ?? 1;
    if (version == 1) return _decodeV1(decoded);
    if (version != 2) throw FormatException('不支持的项目包版本：$version');
    final manifest = decoded['manifest'] is Map
        ? (decoded['manifest'] as Map).cast<String, dynamic>()
        : decoded.cast<String, dynamic>();
    return _snapshotFromManifest(
      manifest,
      id: decoded['project_id'] as String? ?? 'project',
      name: decoded['project_name'] as String? ?? '未命名项目',
    );
  }

  static Map<String, dynamic> _manifest(ProjectSnapshot project) => {
    'video': project.video == null
        ? null
        : {
            'name': project.video!.name,
            'path_hint': project.video!.path,
            'duration_ms': project.video!.durationMs,
            'width': project.video!.width,
            'height': project.video!.height,
            'size_bytes': project.video!.sizeBytes,
            if (project.video!.sha256 != null)
              'fingerprint': project.video!.sha256,
          },
    'roi': {
      if (project.hoopRoi != null) 'analysis': project.hoopRoi!.toJson(),
      if (project.rimRoi != null) 'rim': project.rimRoi!.toJson(),
      if (project.netRoi != null) 'net': project.netRoi!.toJson(),
    },
    'settings': project.settings.toJson(),
    'candidates': project.candidates
        .map((candidate) => candidate.toJson())
        .toList(),
    'players': project.players,
    'review': {
      if (project.lastAnalysisStatus != null)
        'analysis_status': project.lastAnalysisStatus,
      if (project.lastAnalysisAt != null)
        'analysis_at': project.lastAnalysisAt!.toUtc().toIso8601String(),
      if (project.lastAnalysisDurationMs != null)
        'analysis_duration_ms': project.lastAnalysisDurationMs,
      if (project.lastExportDurationMs != null)
        'export_duration_ms': project.lastExportDurationMs,
    },
  };

  static ProjectSnapshot _decodeV1(Map decoded) {
    final project = decoded['project'];
    if (project is! Map) throw const FormatException('项目数据缺失');
    return ProjectSnapshot.fromJson(project.cast<String, dynamic>());
  }

  static ProjectSnapshot _snapshotFromManifest(
    Map<String, dynamic> manifest, {
    required String id,
    required String name,
  }) {
    final rawVideo = manifest['video'];
    final video = rawVideo is Map
        ? VideoInfo.fromJson({
            ...rawVideo.cast<String, dynamic>(),
            'path': rawVideo['path_hint'] ?? '',
            'sha256': rawVideo['fingerprint'],
          })
        : null;
    final rawRoi = manifest['roi'];
    final roi = rawRoi is Map
        ? rawRoi.cast<String, dynamic>()
        : const <String, dynamic>{};
    final rawReview = manifest['review'];
    final review = rawReview is Map
        ? rawReview.cast<String, dynamic>()
        : const <String, dynamic>{};
    return ProjectSnapshot(
      id: id,
      name: name,
      video: video,
      hoopRoi: _roiValue(roi['analysis']),
      rimRoi: _roiValue(roi['rim']),
      netRoi: _roiValue(roi['net']),
      settings: AnalysisSettings.fromJson(
        (manifest['settings'] as Map?)?.cast<String, dynamic>() ?? {},
      ),
      candidates: ((manifest['candidates'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => Candidate.fromJson(item.cast<String, dynamic>()))
          .toList(),
      players: ((manifest['players'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
      lastAnalysisStatus: review['analysis_status'] as String?,
      lastAnalysisAt: DateTime.tryParse(review['analysis_at'] as String? ?? ''),
      lastAnalysisDurationMs: (review['analysis_duration_ms'] as num?)?.toInt(),
      lastExportDurationMs: (review['export_duration_ms'] as num?)?.toInt(),
    );
  }

  static Roi? _roiValue(Object? value) {
    if (value is! Map) return null;
    return Roi.fromJson(value.cast<String, dynamic>());
  }
}
