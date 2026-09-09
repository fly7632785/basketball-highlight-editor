import 'dart:convert';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('analysis settings persist the runtime contract values', () {
    const settings = AnalysisSettings(
      mode: AnalysisMode.highQuality,
      sampleFps: 4.0,
      confidenceThreshold: .12,
      modelSize: 640,
    );

    final restored = AnalysisSettings.fromJson(settings.toJson());

    expect(restored.mode, AnalysisMode.highQuality);
    expect(restored.analysisFps, 4.0);
    expect(restored.confidenceThreshold, .12);
    expect(restored.modelInputSize, 640);
    expect(restored.inferenceBatchSize, 4);
  });

  test('candidate evidence round-trips through the project schema', () {
    const candidate = Candidate(
      id: 'candidate_1200',
      startMs: 0,
      endMs: 4200,
      eventMs: 1200,
      confidence: .82,
      trajectoryScore: .76,
      crossingScore: .94,
      netScore: .63,
      netMotionScore: .41,
      predictionScore: .91,
      predictionFitR2: .96,
      predictionLandingCenter: .94,
      predictionPointCount: 8,
      trackId: 3,
      trajectory: [
        EvidencePoint(timeMs: 900, x: .42, y: .31, confidence: .66),
        EvidencePoint(timeMs: 1200, x: .48, y: .5, confidence: .82),
      ],
      abovePoint: EvidencePoint(timeMs: 1000, x: .47, y: .42),
      belowPoint: EvidencePoint(timeMs: 1300, x: .49, y: .56),
      crossingPoint: EvidencePoint(timeMs: 1200, x: .48, y: .5),
      predictedLandingPoint: EvidencePoint(timeMs: 1500, x: .49, y: .5),
      reason: 'uncertain',
      verdict: 'ambiguous',
      completeCrossing: true,
      netSignalAvailable: true,
      netSupport: true,
      netLowerPeak: .72,
      netBelowPeak: .64,
      algorithmVersion: 'analysis-contract-v1',
      evidenceSource: 'rust_onnx',
    );

    final restored = Candidate.fromJson(candidate.toJson());

    expect(restored.id, candidate.id);
    expect(restored.confidence, candidate.confidence);
    expect(restored.trackId, 3);
    expect(restored.trajectory, hasLength(2));
    expect(restored.trajectory.first.timeMs, 900);
    expect(restored.crossingPoint?.x, .48);
    expect(restored.completeCrossing, isTrue);
    expect(restored.abovePoint?.timeMs, 1000);
    expect(restored.belowPoint?.timeMs, 1300);
    expect(restored.netLowerPeak, .72);
    expect(restored.netScore, .63);
    expect(restored.predictionScore, .91);
    expect(restored.predictionFitR2, .96);
    expect(restored.predictionLandingCenter, .94);
    expect(restored.predictionPointCount, 8);
    expect(restored.predictedLandingPoint?.x, .49);
    expect(restored.algorithmVersion, 'analysis-contract-v1');
    expect(restored.evidenceSource, 'rust_onnx');
  });

  test(
    'desktop overlay evidence accepts seconds and review suggestion fields',
    () {
      final candidate = Candidate.fromJson({
        'id': 'desktop_candidate',
        'review_start_ms': 1000,
        'review_end_ms': 5000,
        'event_time_ms': 3000,
        'confidence': 'medium',
        'evidence': {
          'trajectory': [
            {'time': 2.5, 'x': .4, 'y': .3},
            {'time': 3.0, 'x': .5, 'y': .5},
          ],
          'crossing': {'time': 3.0, 'x': .5, 'y': .5, 'valid': true},
          'review_reason_suggestion': {'primary': 'net_no_motion'},
          'analysis_source': 'desktop_engine',
        },
      });

      expect(candidate.confidence, .6);
      expect(candidate.trajectory.first.timeMs, 2500);
      expect(candidate.crossingPoint?.timeMs, 3000);
      expect(candidate.reason, 'net_no_motion');
      expect(candidate.evidenceSource, 'desktop_engine');
    },
  );

  test('project package v2 round-trips portable manifest fields', () {
    const project = ProjectSnapshot(
      id: 'project-v2',
      name: '测试项目',
      video: VideoInfo(
        path: '/tmp/source.mp4',
        name: 'source.mp4',
        sizeBytes: 1234,
        durationMs: 60000,
        width: 1920,
        height: 1080,
        sha256: 'fingerprint',
      ),
      hoopRoi: Roi(left: .1, top: .2, right: .8, bottom: .9),
      rimRoi: Roi(left: .3, top: .4, right: .5, bottom: .45),
      netRoi: Roi(left: .3, top: .45, right: .5, bottom: .7),
      candidates: [
        Candidate(
          id: 'candidate-1',
          startMs: 1000,
          endMs: 5000,
          eventMs: 2500,
          player: 'A',
          selection: CandidateSelection.excluded,
          verdict: 'ambiguous',
        ),
      ],
      players: ['A'],
      lastAnalysisStatus: 'completed',
      lastAnalysisDurationMs: 42,
    );

    final codec = const ProjectPackageCodec();
    final encoded = codec.encode(project);
    final decodedJson = jsonDecode(encoded) as Map<String, dynamic>;
    final restored = codec.decode(encoded);

    expect(decodedJson['version'], 2);
    expect(decodedJson['manifest'], isNotNull);
    expect(restored.id, project.id);
    expect(restored.name, project.name);
    expect(restored.video?.sha256, 'fingerprint');
    expect(restored.hoopRoi?.left, .1);
    expect(restored.rimRoi?.top, .4);
    expect(restored.netRoi?.bottom, .7);
    expect(restored.candidates.single.selection, CandidateSelection.excluded);
    expect(restored.candidates.single.player, 'A');
    expect(restored.lastAnalysisStatus, 'completed');
  });

  test('project package v1 remains readable', () {
    const project = ProjectSnapshot(id: 'legacy', name: '旧项目', video: null);
    final content = jsonEncode({
      'format': 'bhe-project',
      'version': 1,
      'project': project.toJson(),
    });

    final restored = const ProjectPackageCodec().decode(content);

    expect(restored.id, 'legacy');
    expect(restored.name, '旧项目');
  });

  test('reads net motion from the dedicated signal field', () {
    final candidate = Candidate.fromJson({
      'id': 'net_signal_candidate',
      'signals': {'net_score': .82, 'net_motion_score': .37},
    });

    expect(candidate.netScore, .82);
    expect(candidate.netMotionScore, .37);
  });
}
