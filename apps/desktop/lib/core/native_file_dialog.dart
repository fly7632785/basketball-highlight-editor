import 'dart:io';

import 'package:flutter/services.dart';

const _fileDialogChannel = MethodChannel('bhe/file_dialog');

Future<void> prepareFileDialog() => _focus('preparePanel');
Future<void> refocusFileDialog() => _focus('refocusPanel');

Future<void> _focus(String method) async {
  if (!Platform.isMacOS) return;
  try {
    await _fileDialogChannel.invokeMethod<bool>(method);
  } on MissingPluginException {
    // Tests and older hosts can still use the ordinary file picker.
  } on PlatformException {
    // Focusing is best effort; never prevent a save dialog from opening.
  }
}
