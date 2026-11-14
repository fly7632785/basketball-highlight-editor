import 'package:file_selector/file_selector.dart';
import 'package:bhe_core/bhe_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final exportOutputPickerProvider = Provider((ref) => ExportOutputPicker());

/// Keeps the native modal boundary replaceable in export regression tests.
class ExportOutputPicker {
  Future<String?> mergedPath({required String typeLabel, String projectName = 'Project'}) async {
    final location = await getSaveLocation(
      suggestedName: 'BHE-${safeFileName(projectName)}-highlights.mp4',
      acceptedTypeGroups: [
        XTypeGroup(label: typeLabel, extensions: ['mp4']),
      ],
    );
    return location?.path;
  }

  Future<String?> directory({required String confirmLabel}) =>
      getDirectoryPath(confirmButtonText: confirmLabel);
}
