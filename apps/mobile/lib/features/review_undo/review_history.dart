import 'package:bhe_core/bhe_core.dart';

enum ReviewChange { selection, player, note, range }

/// Only fields belonging to this review operation are retained.
class ReviewFields {
  const ReviewFields({
    this.selection,
    this.reviewed,
    this.player,
    this.note,
    this.startMs,
    this.endMs,
    this.rangeEdited,
  });
  final CandidateSelection? selection;
  final bool? reviewed;
  final String? player;
  final String? note;
  final int? startMs;
  final int? endMs;
  final bool? rangeEdited;

  factory ReviewFields.capture(ReviewChange kind, Candidate c) =>
      switch (kind) {
        ReviewChange.selection => ReviewFields(
          selection: c.selection,
          reviewed: c.reviewed,
        ),
        ReviewChange.player => ReviewFields(player: c.player),
        ReviewChange.note => ReviewFields(note: c.note),
        ReviewChange.range => ReviewFields(
          startMs: c.startMs,
          endMs: c.endMs,
          rangeEdited: c.rangeEdited,
        ),
      };

  Candidate apply(Candidate current, ReviewChange kind) => switch (kind) {
    ReviewChange.selection => current.copyWith(
      selection: selection,
      reviewed: reviewed,
    ),
    ReviewChange.player => current.copyWith(
      player: player,
      clearPlayer: player == null,
    ),
    ReviewChange.note => current.copyWith(note: note, clearNote: note == null),
    ReviewChange.range => current.copyWith(
      startMs: startMs,
      endMs: endMs,
      rangeEdited: rangeEdited,
    ),
  };
}

class ReviewEntry {
  ReviewEntry(this.kind, this.before, this.focusId, {this.foldedView});
  final ReviewChange kind;
  final Map<String, ReviewFields> before;
  final String focusId;
  final bool? foldedView;
  int sequence = -1;
}

class ReviewHistory {
  final List<ReviewEntry> _entries = [];
  final List<ReviewEntry> _pending = [];
  int _sequence = 0;
  Iterable<ReviewEntry> get allEntries => [..._entries, ..._pending];
  bool get canUndo => _entries.isNotEmpty;
  void clear() {
    _entries.clear();
    _pending.clear();
  }

  void add(ReviewEntry entry) {
    if (entry.before.isEmpty) return;
    if (entry.sequence < 0) entry.sequence = _sequence++;
    _entries.add(entry);
    _entries.sort((a, b) => a.sequence.compareTo(b.sequence));
    if (_entries.length > 20) _entries.removeAt(0);
  }

  void remapPlayer(String oldName, String? newName) {
    for (final entry in allEntries) {
      if (entry.kind != ReviewChange.player) continue;
      for (final item in entry.before.entries.toList()) {
        if (item.value.player == oldName) {
          entry.before[item.key] = ReviewFields(player: newName);
        }
      }
    }
  }

  ReviewEntry? pop() {
    if (_entries.isEmpty) return null;
    final entry = _entries.removeLast();
    _pending.add(entry);
    return entry;
  }

  bool complete(ReviewEntry entry) => _pending.remove(entry);
  bool restore(ReviewEntry entry) {
    if (!_pending.remove(entry)) return false;
    add(entry);
    return true;
  }
}

Candidate restoreReviewFields(
  Candidate current,
  ReviewFields fields,
  ReviewChange kind,
) => fields.apply(current, kind);
