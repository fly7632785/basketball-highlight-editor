import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:bhe_mobile/main.dart';

void main() {
  testWidgets('shows the mobile loading shell', (tester) async {
    await tester.pumpWidget(const BheMobileApp());
    // Startup restores a real filesystem project and may keep a progress
    // indicator alive while that read completes. Flush the first frame only;
    // the app's loading state is covered by the explicit loading widget test.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
