import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/bhe_file_dialog.dart';

final exportOutputPickerProvider = Provider((ref) => ExportOutputPicker());

/// Keeps the native modal boundary replaceable in export regression tests.
class ExportOutputPicker {
  Future<String?> mergedPath({required String typeLabel}) async {
    return BheFileDialog.getSaveLocation(
      suggestedName: 'highlights.mp4',
      typeLabel: typeLabel,
      extensions: ['mp4'],
    );
  }

  Future<String?> directory({required String confirmLabel}) =>
      BheFileDialog.getDirectoryPath(confirmLabel: confirmLabel);
}
