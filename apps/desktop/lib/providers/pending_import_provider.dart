import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Video paths dropped on the home screen, waiting for the import screen to
/// pick them up after the new project opens.
class PendingImportNotifier extends Notifier<List<String>?> {
  @override
  List<String>? build() => null;

  void set(List<String> paths) => state = paths;

  List<String>? take() {
    final paths = state;
    state = null;
    return paths;
  }
}

final pendingImportProvider =
    NotifierProvider<PendingImportNotifier, List<String>?>(
      PendingImportNotifier.new,
    );

const importVideoExtensions = <String>{'mp4', 'mov', 'm4v', 'avi', 'mkv'};

bool isImportableVideo(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 &&
      importVideoExtensions.contains(path.substring(dot + 1).toLowerCase());
}
