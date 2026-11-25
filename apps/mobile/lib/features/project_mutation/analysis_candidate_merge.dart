import 'package:bhe_core/bhe_core.dart';

/// Refresh engine evidence without overwriting review decisions made while the
/// analysis stream is still running.
List<Candidate> mergeAnalysisCandidates(
  List<Candidate> current,
  List<Candidate> incoming,
) {
  final previous = {for (final candidate in current) candidate.id: candidate};
  final result = <Candidate>[];
  for (final candidate in incoming) {
    final old = previous.remove(candidate.id);
    if (old == null) {
      result.add(candidate);
    } else {
      result.add(
        candidate.copyWith(
          selection: old.selection,
          reviewed: old.reviewed,
          players: old.effectivePlayers,
          note: old.note,
          clearNote: old.note == null,
          startMs: old.rangeEdited ? old.startMs : null,
          endMs: old.rangeEdited ? old.endMs : null,
          rangeEdited: old.rangeEdited,
        ),
      );
    }
  }
  for (final old in previous.values) {
    if (old.reviewed ||
        old.rangeEdited ||
        old.effectivePlayers.isNotEmpty ||
        old.note != null ||
        old.reason == 'manual' ||
        old.selection == CandidateSelection.excluded) {
      result.add(old);
    }
  }
  result.sort((a, b) => a.eventMs.compareTo(b.eventMs));
  return result;
}

/// Carry labels across a completed rerun using the existing ID match.
List<Candidate> inheritAnalysisTags(
  List<Candidate> previous,
  List<Candidate> incoming,
) {
  final byId = {for (final candidate in previous) candidate.id: candidate};
  return [
    for (final candidate in incoming)
      if (byId[candidate.id] case final exact?)
        candidate.copyWith(players: exact.effectivePlayers)
      else
        candidate,
  ]..sort((a, b) => a.eventMs.compareTo(b.eventMs));
}
