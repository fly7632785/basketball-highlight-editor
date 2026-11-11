import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// 在资源管理器里打开 [directory](目录模式),或打开所在文件夹并选中
/// [select](文件定位模式)。
///
/// 不走 `explorer.exe /select,<路径>` 命令行:该解析对正斜杠、空格和引号
/// 都很挑剔,任一形式解析失败时资源管理器会回退打开「文档」,曾导致导出
/// 后「打开目录」定位不到文件。改用 shell API(SHParseDisplayName +
/// SHOpenFolderAndSelectItems / ShellExecuteW),路径以宽字符传递,行为在
/// Win10/Win11 上一致。
void openInWindowsExplorer({required String directory, String? select}) {
  final ole32 = ffi.DynamicLibrary.open('ole32.dll');
  final coInitializeEx =
      ole32
          .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32),
            int Function(ffi.Pointer<ffi.Void>, int)
          >('CoInitializeEx');
  // 平台线程由 Flutter 引擎初始化过 COM(STA);这里再次调用只增加引用
  // 计数(S_FALSE),不配对释放,避免影响引擎自身的 COM 生命周期。
  coInitializeEx(ffi.nullptr, 2 /* COINIT_APARTMENTTHREADED */);

  final shell32 = ffi.DynamicLibrary.open('shell32.dll');
  final shellExecuteW =
      shell32.lookupFunction<
        ffi.IntPtr Function(
          ffi.IntPtr,
          ffi.Pointer<ffi.Uint16>,
          ffi.Pointer<ffi.Uint16>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>,
          ffi.Int32,
        ),
        int Function(
          int,
          ffi.Pointer<ffi.Uint16>,
          ffi.Pointer<ffi.Uint16>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>,
          int,
        )
      >('ShellExecuteW');
  final parseDisplayName =
      shell32.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint16>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Pointer<ffi.Uint16>>,
          ffi.Uint32,
          ffi.Pointer<ffi.Uint32>,
        ),
        int Function(
          ffi.Pointer<ffi.Uint16>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Pointer<ffi.Uint16>>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )
      >('SHParseDisplayName');
  final openAndSelect =
      shell32.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Uint16>,
          ffi.Uint32,
          ffi.Pointer<ffi.Pointer<ffi.Uint16>>,
          ffi.Uint32,
        ),
        int Function(
          ffi.Pointer<ffi.Uint16>,
          int,
          ffi.Pointer<ffi.Pointer<ffi.Uint16>>,
          int,
        )
      >('SHOpenFolderAndSelectItems');

  void shellOpen(String path) {
    final pathPtr = path.toNativeUtf16();
    final verbPtr = 'open'.toNativeUtf16();
    try {
      shellExecuteW(
        0,
        verbPtr.cast<ffi.Uint16>(),
        pathPtr.cast<ffi.Uint16>(),
        ffi.nullptr,
        ffi.nullptr,
        5 /* SW_SHOWNORMAL */,
      );
    } finally {
      malloc.free(verbPtr);
      malloc.free(pathPtr);
    }
  }

  if (select == null || select.isEmpty) {
    shellOpen(directory);
    return;
  }

  final namePtr = select.toNativeUtf16();
  final pidl = calloc<ffi.Pointer<ffi.Uint16>>();
  try {
    final hr = parseDisplayName(
      namePtr.cast<ffi.Uint16>(),
      ffi.nullptr,
      pidl,
      0,
      ffi.nullptr,
    );
    if (hr < 0 || pidl.value == ffi.nullptr) {
      // 路径解析失败时目录还是照常打开(不带选中),总好过落到「文档」。
      shellOpen(directory);
      return;
    }
    openAndSelect(pidl.value, 0, ffi.nullptr, 0);
  } finally {
    calloc.free(pidl);
    malloc.free(namePtr);
  }
}
