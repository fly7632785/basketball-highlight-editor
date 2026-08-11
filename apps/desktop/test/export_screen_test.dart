import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/export/export_screen.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets('导出历史提供打开目录按钮', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(
            () => _ExportNotifier(
              const ProjectState(
                exportHistory: [
                  {
                    'mode': 'merge',
                    'candidate_count': 2,
                    'duration_ms': 12000,
                    'processing_ms': 3000,
                    'output_path': '/tmp/highlights.mp4',
                    'metadata': {
                      'files': ['/tmp/highlights.mp4'],
                    },
                    'created_at': '2026-08-07T01:00:00.000Z',
                  },
                ],
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: const Scaffold(body: ExportScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('打开目录'), findsOneWidget);
  });
}

class _ExportNotifier extends ProjectNotifier {
  _ExportNotifier(this.initialState);

  final ProjectState initialState;

  @override
  ProjectState build() => initialState;
}
