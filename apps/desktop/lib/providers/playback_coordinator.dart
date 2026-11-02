import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/video_orientation.dart';

final playbackCoordinatorProvider = Provider((ref) => PlaybackCoordinator());

/// 弹原生选择框之前先把视频画面（纹理）从树里摘掉，等一帧渲染完再弹。
/// 不再先 pause 播放器：Windows 上动正在显示的视频输出可能卡死平台线程，
/// Dart 侧的超时救不了。准备阶段超过 [prepareTimeout] 就不等了，直接弹框。
class PlaybackCoordinator {
  PlaybackCoordinator({
    this.prepareTimeout = const Duration(seconds: 10),
    Future<void> Function()? nextFrame,
  }) : _nextFrame = nextFrame ?? (() => WidgetsBinding.instance.endOfFrame);

  final Duration prepareTimeout;
  final Future<void> Function() _nextFrame;
  bool _dialogActive = false;

  bool get dialogActive => _dialogActive;

  Future<T> withNativeDialog<T>(
    Future<T> Function() showDialog, {
    void Function()? onPrepareTimeout,
  }) async {
    if (_dialogActive) throw StateError('An output dialog is already open');
    _dialogActive = true;
    final releaseVideo = holdVideoSurfaceHidden();
    try {
      try {
        await _nextFrame().timeout(prepareTimeout);
      } on TimeoutException {
        onPrepareTimeout?.call();
      }
      return await showDialog();
    } finally {
      // Do not automatically resume hidden players when a modal closes.
      releaseVideo();
      _dialogActive = false;
    }
  }
}
