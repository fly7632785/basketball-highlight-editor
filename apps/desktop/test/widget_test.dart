import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/app.dart';

void main() {
  testWidgets('renders the project workspace', (tester) async {
    await tester.pumpWidget(
      const BasketballHighlightApp(enableStartupProjectScan: false),
    );
    expect(find.text('把整场比赛，变成你的高光。'), findsOneWidget);
    expect(find.text('新建项目'), findsWidgets);
  });
}
