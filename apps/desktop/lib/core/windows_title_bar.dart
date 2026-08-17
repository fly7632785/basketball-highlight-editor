import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart' show Brightness;

const int _dwmwaUseImmersiveDarkMode = 20;

/// 直接通过 DWM 设置 Windows 标题栏深浅。
///
/// window_manager 的 setBrightness 在 Windows 上只有在系统主题本身
/// 为深色时才应用暗色标题栏(读 AppsUseLightTheme 注册表做门控)，
/// 系统浅色 + 应用深色时标题栏会保持白色；这里绕过该限制。
void applyWindowsTitleBarBrightness(Brightness brightness) {
  if (!Platform.isWindows) return;
  try {
    final dwmapi = ffi.DynamicLibrary.open('dwmapi.dll');
    final user32 = ffi.DynamicLibrary.open('user32.dll');
    final findWindowW =
        user32.lookupFunction<
          ffi.IntPtr Function(
            ffi.Pointer<ffi.Uint16>,
            ffi.Pointer<ffi.Uint16>,
          ),
          int Function(ffi.Pointer<ffi.Uint16>, ffi.Pointer<ffi.Uint16>)
        >('FindWindowW');
    final dwmSetWindowAttribute =
        dwmapi.lookupFunction<
          ffi.Int32 Function(
            ffi.IntPtr,
            ffi.Uint32,
            ffi.Pointer<ffi.Int32>,
            ffi.Uint32,
          ),
          int Function(int, int, ffi.Pointer<ffi.Int32>, int)
        >('DwmSetWindowAttribute');

    final title = 'BHE'.toNativeUtf16();
    try {
      final hwnd = findWindowW(ffi.nullptr, title.cast<ffi.Uint16>());
      if (hwnd == 0) return;
      final value = calloc<ffi.Int32>();
      try {
        value.value = brightness == Brightness.dark ? 1 : 0;
        dwmSetWindowAttribute(
          hwnd,
          _dwmwaUseImmersiveDarkMode,
          value,
          ffi.sizeOf<ffi.Int32>(),
        );
      } finally {
        calloc.free(value);
      }
    } finally {
      malloc.free(title);
    }
  } catch (_) {
    // DWM 不可用(旧版 Windows)或句柄未就绪时静默跳过。
  }
}
