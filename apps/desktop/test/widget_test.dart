import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:desktop/app.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/session_provider.dart';

void main() {
  testWidgets('renders the project workspace', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          engineBootstrapProvider.overrideWith(() => _StubEngine()),
          projectProvider.overrideWith(_StubProject.new),
        ],
        child: const BasketballHighlightApp(enableStartupProjectScan: false),
      ),
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            (widget.data == '把整场比赛，变成你的高光。' ||
                widget.data == 'Turn the whole game into your highlights.'),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            (widget.data == '新建项目' || widget.data == 'New project'),
      ),
      findsWidgets,
    );
  });
}

class _StubEngine extends EngineBootstrapNotifier {
  @override
  AsyncValue<bool> build() => const AsyncData<bool>(true);
}

class _StubProject extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState();

  @override
  Future<void> loadRecentProjects() async {}
}
