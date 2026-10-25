import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/components/cs_button.dart';
import 'package:desktop/features/export/existing_video_merge_dialog.dart';
import 'package:desktop/providers/export_output_picker.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets(
    'merge button stays disabled until videos and output are chosen',
    (tester) async {
      await _pumpDialog(tester, picker: _MergePicker());

      expect(
        tester
            .widget<CsButton>(
              find.byKey(const Key('existing-video-merge-start')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('merge dispatches videos in the reordered list order', (
    tester,
  ) async {
    final picker = _MergePicker(
      videos: const ['/tmp/first.mp4', '/tmp/second.mp4'],
      output: '/tmp/merged.mp4',
    );
    List<String>? mergedInputs;
    String? mergedOutput;
    await _pumpDialog(
      tester,
      picker: picker,
      onMerge: (inputs, output) async {
        mergedInputs = inputs;
        mergedOutput = output;
      },
    );

    await tester.tap(find.text('选择视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('existing-video-up-1')));
    await tester.tap(find.text('选择保存位置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('existing-video-merge-start')));
    await tester.pumpAndSettle();

    expect(mergedInputs, ['/tmp/second.mp4', '/tmp/first.mp4']);
    expect(mergedOutput, '/tmp/merged.mp4');
  });
}

Future<void> _pumpDialog(
  WidgetTester tester, {
  required _MergePicker picker,
  Future<void> Function(List<String> inputs, String output)? onMerge,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.dark),
      home: Scaffold(
        body: ExistingVideoMergeDialog(picker: picker, onMerge: onMerge),
      ),
    ),
  );
}

class _MergePicker extends ExportOutputPicker {
  _MergePicker({this.videos = const [], this.output});

  final List<String> videos;
  final String? output;

  @override
  Future<List<String>> existingVideos({required String typeLabel}) async =>
      videos;

  @override
  Future<String?> existingVideosMergedPath({required String typeLabel}) async =>
      output;
}
