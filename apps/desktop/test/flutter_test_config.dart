import 'dart:async';
import 'dart:io';

import 'package:desktop/core/app_log.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final dir = Directory.systemTemp.createTempSync('bhe_test_log_');
  appLogFileOverride = File('${dir.path}/engine.log');
  tearDownAll(() {
    appLogFileOverride = null;
    dir.deleteSync(recursive: true);
  });
  await testMain();
}
