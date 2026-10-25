import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final exportOutputPickerProvider = Provider((ref) => ExportOutputPicker());

/// Keeps the native modal boundary replaceable in export regression tests.
class ExportOutputPicker {
  Future<List<String>> existingVideos({required String typeLabel}) async {
    final files = await openFiles(
      acceptedTypeGroups: [
        XTypeGroup(label: typeLabel, extensions: ['mp4', 'mov', 'mkv', 'avi']),
      ],
    );
    return files.map((file) => file.path).toList(growable: false);
  }

  Future<String?> existingVideosMergedPath({required String typeLabel}) async {
    final location = await getSaveLocation(
      suggestedName: 'merged-videos.mp4',
      acceptedTypeGroups: [
        XTypeGroup(label: typeLabel, extensions: ['mp4']),
      ],
    );
    return location?.path;
  }

  Future<String?> mergedPath({required String typeLabel}) async {
    final location = await getSaveLocation(
      suggestedName: 'highlights.mp4',
      acceptedTypeGroups: [
        XTypeGroup(label: typeLabel, extensions: ['mp4']),
      ],
    );
    return location?.path;
  }

  Future<String?> directory({required String confirmLabel}) =>
      getDirectoryPath(confirmButtonText: confirmLabel);
}
