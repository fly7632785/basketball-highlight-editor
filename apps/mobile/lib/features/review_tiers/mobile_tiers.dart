import 'package:bhe_core/bhe_core.dart';

enum MobileTier {
  goal('进球'),
  uncertain('疑似'),
  excluded('排除');

  const MobileTier(this.label);
  final String label;
}

MobileTier mobileTier(Candidate candidate) {
  if (candidate.reviewed) {
    return candidate.selection == CandidateSelection.included
        ? MobileTier.goal
        : MobileTier.excluded;
  }
  if (candidate.selection == CandidateSelection.excluded ||
      candidate.rimCheckStatus == 'rejected') {
    return MobileTier.excluded;
  }
  return MobileTier.uncertain;
}

bool isFoldedCandidate(Candidate candidate, Set<String> foldedIds) =>
    foldedIds.contains(candidate.id) &&
    mobileTier(candidate) == MobileTier.uncertain;
