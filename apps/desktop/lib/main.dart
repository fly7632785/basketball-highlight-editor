import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';

void main() {
  MediaKit.ensureInitialized();
  runApp(const BasketballHighlightApp());
}
