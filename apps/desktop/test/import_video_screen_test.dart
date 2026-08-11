import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/import_video/import_video_screen.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('renders the calibration workspace without a selected video', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          projectProvider.overrideWith(_ImportNotifier.new),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: const Scaffold(body: ImportVideoScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('导入与校准'), findsOneWidget);
    expect(find.text('选择视频'), findsOneWidget);
    expect(find.text('请先选择视频'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _ImportNotifier extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState();
}
