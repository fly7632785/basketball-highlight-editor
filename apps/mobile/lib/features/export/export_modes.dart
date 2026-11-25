import 'package:bhe_core/bhe_core.dart';

import '../review_tiers/mobile_tiers.dart';

enum MobileOutputMode { clips, merged, labels }

const defaultMobileExportTiers = {MobileTier.goal, MobileTier.uncertain};

class ExportScope {
  const ExportScope.only(
    this.players, {
    this.includeUntagged = false,
    this.tiers = defaultMobileExportTiers,
  }) : active = true;

  const ExportScope.anyTag({this.tiers = defaultMobileExportTiers})
    : active = false,
      players = const {},
      includeUntagged = true;

  static const all = ExportScope.anyTag();

  final Set<MobileTier> tiers;
  final bool active;
  final Set<String> players;
  final bool includeUntagged;

  ExportScope withTiers(Set<MobileTier> tiers) => active
      ? ExportScope.only(
          players,
          includeUntagged: includeUntagged,
          tiers: tiers,
        )
      : ExportScope.anyTag(tiers: tiers);

  bool matches(Candidate candidate) {
    if (!active) return true;
    final labels = exportLabels(candidate);
    return labels.isEmpty ? includeUntagged : labels.any(players.contains);
  }

  List<Candidate> select(
    Iterable<Candidate> candidates,
    MobileOutputMode mode,
  ) => candidates
      .where(
        (candidate) =>
            tiers.contains(mobileTier(candidate)) &&
            matches(candidate) &&
            (mode != MobileOutputMode.labels ||
                exportLabels(candidate).isNotEmpty),
      )
      .toList();

  ExportScope get normalized => active && players.isEmpty && !includeUntagged
      ? ExportScope.anyTag(tiers: tiers)
      : this;
}

Set<String> exportLabels(Candidate candidate) => {
  for (final label in candidate.effectivePlayers)
    if (label.trim().isNotEmpty) label,
};

class LabelExportGroup {
  const LabelExportGroup(this.label, this.candidates);
  final String label;
  final List<Candidate> candidates;
}

class LabelExportFile {
  const LabelExportFile(this.label, this.path);
  final String? label;
  final String path;
}

List<LabelExportGroup> labelExportGroups(
  Iterable<Candidate> candidates, {
  ExportScope scope = ExportScope.all,
}) {
  final groups = <String, List<Candidate>>{};
  for (final candidate in candidates) {
    for (final label in exportLabels(candidate)) {
      if (!scope.active || scope.players.contains(label)) {
        (groups[label] ??= []).add(candidate);
      }
    }
  }
  return [
    for (final entry in groups.entries)
      LabelExportGroup(entry.key, entry.value),
  ];
}
