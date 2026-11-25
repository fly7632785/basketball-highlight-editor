part of '../../mobile_app_state.dart';

class MobileExportRequest {
  MobileExportRequest({
    required ExportScope scope,
    required this.mode,
    required this.framing,
    required Iterable<Candidate> candidates,
  }) : scope = scope.active
           ? ExportScope.only(
               Set.unmodifiable(scope.players),
               includeUntagged: scope.includeUntagged,
               tiers: Set.unmodifiable(scope.tiers),
             )
           : ExportScope.anyTag(tiers: Set.unmodifiable(scope.tiers)),
       candidates = List.unmodifiable(
         candidates.map(
           (clip) =>
               clip.copyWith(players: List.unmodifiable(clip.effectivePlayers)),
         ),
       );

  final ExportScope scope;
  final MobileOutputMode mode;
  final ExportFraming framing;
  final List<Candidate> candidates;

  late final List<LabelExportGroup> groups = labelExportGroups(
    candidates,
    scope: scope,
  );

  int get outputCount => switch (mode) {
    MobileOutputMode.clips => candidates.length,
    MobileOutputMode.merged => candidates.isEmpty ? 0 : 1,
    MobileOutputMode.labels => groups.length,
  };

  MobileExportRequest withFraming(ExportFraming value) => MobileExportRequest(
    scope: scope,
    mode: mode,
    framing: value,
    candidates: candidates,
  );
}

typedef MobileExportFailure = ({
  String message,
  DiagnosticErrorRecord? diagnostic,
});

class MobileExportResult {
  const MobileExportResult({
    required this.request,
    required this.files,
    required this.cancelled,
    required this.failure,
    required this.portraitProgress,
    required this.audioSkipped,
    required this.mergedOverlapCount,
    required this.noBallCount,
  });

  final MobileExportRequest request;
  final List<LabelExportFile> files;
  final bool cancelled;
  final MobileExportFailure? failure;
  final PortraitExportProgress? portraitProgress;
  final bool audioSkipped;
  final int? mergedOverlapCount;
  final int noBallCount;
}
