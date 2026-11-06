import 'dart:async';

import 'app_log.dart';

/// 关闭应用前需要落盘的页面在这里登记一个「立即保存待写内容」的回调。
///
/// 为什么不用 Riverpod：关闭流程在 [App] 的窗口回调里，页面可能已经卸载，
/// 这里只需要「有就调用、没有就跳过」，一个极小的注册表足够，不引额外状态。
typedef DraftFlushCallback = Future<void> Function();

final Set<DraftFlushCallback> _callbacks = <DraftFlushCallback>{};

void registerDraftFlush(DraftFlushCallback callback) => _callbacks.add(callback);

void unregisterDraftFlush(DraftFlushCallback callback) =>
    _callbacks.remove(callback);

/// 退出前把登记过页面里的待写草稿写完。
///
/// 超时也放行：关闭窗口不能被一次写盘卡住，草稿丢了比关不掉软件可接受。
/// 没有页面登记时立即返回（无操作）。
Future<void> flushDraftBeforeShutdown({
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (_callbacks.isEmpty) return;
  final pending = [for (final callback in _callbacks.toList()) callback()];
  try {
    await Future.wait(pending).timeout(timeout);
  } on TimeoutException {
    appLog('warn', 'app', '关闭前保存草稿超时 ${timeout.inMilliseconds}ms，继续退出');
  } catch (error) {
    appLog('warn', 'app', '关闭前保存草稿失败: $error');
  }
}

/// 测试用：清空登记表，避免用例之间互相污染。
void resetDraftFlushForTest() => _callbacks.clear();
