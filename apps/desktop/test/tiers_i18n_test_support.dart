import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadSdkTextFont() async {
  // Ahem's square advances cannot validate translated text or guide geometry.
  final root = Platform.environment['FLUTTER_ROOT'];
  final file = File(
    '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  expect(file.existsSync(), isTrue, reason: 'Flutter SDK text font required');
  final data = ByteData.sublistView(await file.readAsBytes());
  for (final family in ['Inter', 'Roboto', 'Ahem']) {
    await (FontLoader(family)..addFont(Future.value(data))).load();
  }
}
