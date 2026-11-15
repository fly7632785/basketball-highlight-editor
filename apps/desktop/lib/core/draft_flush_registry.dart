import 'dart:async';

import 'app_log.dart';

/// 关闭应用前需要落盘的页面在这里登记一个「立即保存待写内容」的回调。
///
/// 为什么不用 Riverpod：关闭流程在 [App] 的窗口回调里，页面可能已经卸载，
/// 这里只需要「有就调用、没有就跳过」，一个极小的注册表足够，不引额外状态。
typedef DraftFlushCallback = Future<void> Function();

final Set<DraftFlushCallback> _callbacks = <DraftFlushCallback>{};
final Set<Future<void>> _pendingWrites = <Future<void>>{};

void registerDraftFlush(DraftFlushCallback callback) => _callbacks.add(callback);

void unregisterDraftFlush(DraftFlushCallback callback) =>
    _callbacks.remove(callback);

/// 页面卸载后仍保留其保存尾任务，让切换项目和退出继续等待原项目落盘。
/// 完成后释放引用；失败也收尾，避免没有等待者时产生未处理的异步异常。
void retainPendingDraftWrite(Future<void> write) {
  late final Future<void> pending;
  pending = write.then<void>(
    (_) => _pendingWrites.remove(pending),
    onError: (Object error, StackTrace stack) {
      _pendingWrites.remove(pending);
      appLog('warn', 'app', '离页草稿保存失败: $error');
    },
  );
  _pendingWrites.add(pending);
}

/// 切换项目或退出前，等待在页草稿及已离页的保存尾任务。
///
/// 超时也放行：关闭窗口不能被一次写盘卡住，草稿丢了比关不掉软件可接受。
/// 没有页面登记且没有离页任务时立即返回（无操作）。
Future<void> flushDraftBeforeShutdown({
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (_callbacks.isEmpty && _pendingWrites.isEmpty) return;
  final pending = [
    ..._pendingWrites,
    for (final callback in _callbacks.toList()) callback(),
  ];
  try {
    await Future.wait(pending).timeout(timeout);
  } on TimeoutException {
    appLog('warn', 'app', '关闭前保存草稿超时 ${timeout.inMilliseconds}ms，继续退出');
  } catch (error) {
    appLog('warn', 'app', '关闭前保存草稿失败: $error');
  }
}

/// 测试用：清空登记表，避免用例之间互相污染。
void resetDraftFlushForTest() {
  _callbacks.clear();
  _pendingWrites.clear();
}
