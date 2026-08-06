import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/app.dart';

void main() {
  testWidgets('renders the project workspace', (tester) async {
    await tester.pumpWidget(
      const BasketballHighlightApp(enableStartupProjectScan: false),
    );
    expect(find.text('篮球集锦编辑器'), findsOneWidget);
    expect(find.text('新建项目'), findsOneWidget);
  });
}
