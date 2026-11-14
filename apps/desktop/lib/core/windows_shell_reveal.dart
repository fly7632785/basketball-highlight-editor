import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// 归一化传给 shell API 的 Windows 路径。
///
/// 导出历史里存的路径用正斜杠(`/`),而 SHParseDisplayName 对
/// 混合分隔符路径很挑剔。全部替换为反斜杠;UNC 前缀 `//nas/share`
/// 会被正确转换成 `\\nas\share`。
String normalizeWindowsShellPath(String path) =>
    path.replaceAll('/', r'\');

/// 在资源管理器里打开 [directory](目录模式),或打开所在文件夹并选中
/// [select](文件定位模式)。
///
/// - 整个 shell 调用在后台 isolate 执行:资源管理器卡住、NAS 掉线、
///   路径指向已离线的网络盘时,界面线程不受影响。
/// - [select] 的存在性检查也在后台 isolate 内完成;文件不存在(含所在
///   网络盘掉线)时退化为仅打开 [directory],不再由调用方预先判断。
/// - 路径先经 [normalizeWindowsShellPath] 归一化为反斜杠。
/// - 不走 `explorer.exe /select,<路径>` 命令行:该解析对正斜杠、空格和
///   引号都很挑剔,任一形式解析失败时资源管理器会回退打开「文档」。
///   改用 shell API(SHParseDisplayName + SHOpenFolderAndSelectItems /
///   ShellExecuteW),路径以宽字符传递,行为在 Win10/Win11 上一致。
/// - ShellExecuteW / SHOpenFolderAndSelectItems 失败时抛出带错误码的
///   异常,调用方的 try/catch 可捕获提示。
Future<void> openInWindowsExplorer({
  required String directory,
  String? select,
}) {
  return Isolate.run(() {
    _revealSync(directory: directory, select: select);
  });
}

/// shell 调用失败的异常,携带可读的错误描述。
class ShellRevealException implements Exception {
  const ShellRevealException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// ShellExecuteW 返回值 ≤ 32 表示失败,常见码翻译为可读描述。
String _shellExecuteError(int code) {
  const known = <int, String>{
    2: '文件未找到',
    3: '路径未找到(可能已掉线或被移除)',
    5: '拒绝访问',
    8: '内存不足',
    26: 'DDE 会话失败',
    28: 'DDE 会话超时(NAS 或网络路径可能离线)',
    31: '没有关联的打开方式',
    32: '所需的动态库未找到',
  };
  final hint = known[code];
  return 'ShellExecuteW 失败 (code=$code${hint == null ? '' : ': $hint'})';
}

void _revealSync({required String directory, String? select}) {
  final ole32 = ffi.DynamicLibrary.open('ole32.dll');
  final coInitializeEx =
      ole32
          .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32),
            int Function(ffi.Pointer<ffi.Void>, int)
          >('CoInitializeEx');
  final coUninitialize =
      ole32
          .lookupFunction<
            ffi.Void Function(),
            void Function()
          >('CoUninitialize');
  // 后台 isolate 的线程没有初始化过 COM;STA 是 shell 对话框/选中
  // 逻辑要求的线程模型。线程来自线程池且会被复用,不随 isolate 结束
  // 销毁,因此 COM 初始化必须与 CoUninitialize 配对:
  // - S_OK(0)/S_FALSE(1):本线程由本次调用初始化(或已按同模型初始化
  //   过),结束时配平调用 CoUninitialize;
  // - RPC_E_CHANGED_MODE(0x80010106):线程已被按其他并发模型初始化,
  //   本次调用没有生效,不能调用 CoUninitialize,否则会拆掉别人的初始化;
  // - 其他失败值:COM 不可用,shell 调用无法安全进行,直接报错。
  final hr = coInitializeEx(
    ffi.nullptr,
    2, /* COINIT_APARTMENTTHREADED */
  ).toUnsigned(32);
  if (hr != 0 /* S_OK */ &&
      hr != 1 /* S_FALSE */ &&
      hr != 0x80010106 /* RPC_E_CHANGED_MODE */) {
    throw ShellRevealException(
      'CoInitializeEx 失败 (hr=0x${hr.toRadixString(16)})',
    );
  }
  final shouldCoUninitialize = hr == 0 || hr == 1;
  try {
    final shell32 = ffi.DynamicLibrary.open('shell32.dll');
    final ilFree =
        shell32.lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)
        >('ILFree');
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

    // 目录模式与文件选中模式都经此收口;返回 false 表示 shell 明确报错。
    void shellOpen(String path, void Function() reportFailure) {
      final pathPtr = path.toNativeUtf16();
      final verbPtr = 'open'.toNativeUtf16();
      try {
        final result = shellExecuteW(
          0,
          verbPtr.cast<ffi.Uint16>(),
          pathPtr.cast<ffi.Uint16>(),
          ffi.nullptr,
          ffi.nullptr,
          5 /* SW_SHOWNORMAL */,
        );
        // 返回值 > 32 为成功(HINSTANCE);≤ 32 是 SE_ERR_* 错误码。
        if (result <= 32) reportFailure();
      } finally {
        malloc.free(verbPtr);
        malloc.free(pathPtr);
      }
    }

    // 导出历史里存的路径用正斜杠,shell API 需要反斜杠。
    // [select] 的存在性检查放在这里(后台 isolate)完成:NAS 掉线时
    // 可能阻塞到网络超时,不能放到界面线程;文件不存在(已被移动/删除
    // 或所在网络盘离线)时退化为仅打开目录。
    final nativeDirectory = normalizeWindowsShellPath(directory);
    final selectMissing =
        select == null || select.isEmpty || !File(select).existsSync();
    final nativeSelect = selectMissing
        ? null
        : normalizeWindowsShellPath(select);

    if (nativeSelect == null) {
      shellOpen(nativeDirectory, () {
        throw ShellRevealException(_shellExecuteError(3));
      });
      return;
    }

    final namePtr = nativeSelect.toNativeUtf16();
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
        shellOpen(nativeDirectory, () {
          throw ShellRevealException(_shellExecuteError(3));
        });
        return;
      }
      final hrOpen = openAndSelect(pidl.value, 0, ffi.nullptr, 0);
      if (hrOpen < 0) {
        throw ShellRevealException(
          'SHOpenFolderAndSelectItems 失败 (hr=0x${hrOpen.toUnsigned(32).toRadixString(16)})',
        );
      }
    } finally {
      // SHParseDisplayName 成功时通过 CoTaskMemAlloc 分配了 PIDL,
      // 必须用 ILFree 释放,否则每次定位文件都泄漏一块 shell 内存。
      if (pidl.value != ffi.nullptr) {
        ilFree(pidl.value.cast<ffi.Void>());
      }
      calloc.free(pidl);
      malloc.free(namePtr);
    }
  } finally {
    if (shouldCoUninitialize) {
      coUninitialize();
    }
  }
}
