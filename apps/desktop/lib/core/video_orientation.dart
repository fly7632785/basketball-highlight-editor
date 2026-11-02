import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 播放器画面的方向修正。
///
/// 手机视频把转正角度写在容器里（`rotation` side data）。Windows 上关了硬件加速，
/// mpv 的软件渲染**不处理旋转**：90/270 度时 media_kit 按转正后的尺寸分配缓冲区，
/// mpv 却按未转的画面裁剪，越界后画面错位、左右重复、带绿边；180 度则原样不转
/// （头下脚上）。用随包 libmpv 的软件渲染在 Mac 上复现过。
///
/// 做法：打开带旋转角的源之前让 mpv 按编码方向输出（[matchPlayerToSourceRotation]），
/// 再由本组件转正：
/// 1. 90/270 度时子组件按编码方向排版（外框宽高互换），外层 [RotatedBox] 转到显示方向；
/// 2. 不强制宽高比：media_kit 把纹理宽、高各自截到 1920×1080 内，竖的 720×1512 会变成
///    带左右黑边的 720×1080，调用方传 `BoxFit.cover` 把黑边裁掉（和 4:3 横拍同一个做法）。
/// 弹原生对话框期间为 true：所有 [OrientedVideo] 换成占位，不再显示视频纹理。
final ValueNotifier<bool> videoSurfaceHidden = ValueNotifier<bool>(false);

class OrientedVideo extends StatelessWidget {
  const OrientedVideo({
    super.key,
    required this.controller,
    required this.rotation,
    this.fit = BoxFit.contain,
  });

  final VideoController? controller;

  /// 源文件声明的旋转角度（引擎 `inspect_video` 返回的 `rotation`），按 ffmpeg 显示矩阵
  /// 的约定是**逆时针**角度：90 表示显示时要把编码画面逆时针转 90°。
  final int rotation;

  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: videoSurfaceHidden,
      builder: (context, hidden, _) => hidden && controller != null
          ? const ColoredBox(color: Colors.black)
          : _buildVideo(),
    );
  }

  Widget _buildVideo() {
    final c = controller;
    if (c == null) {
      return const SizedBox.shrink();
    }
    final turns = rotationQuarterTurns(rotation);
    final child = Video(controller: c, fit: fit, controls: NoVideoControls);
    if (turns == 0) return child;
    if (turns % 2 == 0) {
      return RotatedBox(quarterTurns: turns, child: child);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return RotatedBox(quarterTurns: turns, child: child);
        }
        return RotatedBox(
          quarterTurns: turns,
          child: SizedBox(
            width: constraints.maxHeight,
            height: constraints.maxWidth,
            child: child,
          ),
        );
      },
    );
  }
}

/// 把逆时针的 [rotation] 换成 [RotatedBox] 用的顺时针四分之一圈数（0/1/2/3），非法值当 0。
int rotationQuarterTurns(int rotation) {
  final normalized = ((-rotation % 360) + 360) % 360;
  switch (normalized) {
    case 90:
      return 1;
    case 180:
      return 2;
    case 270:
      return 3;
    default:
      return 0;
  }
}

/// 调试用：`--dart-define=BHE_SOFTWARE_VIDEO=true` 让 Mac 也按 Windows 的方式播放
/// （软件渲染 + 自己转画面），不用回到 Windows 就能检查带旋转角的视频。
const _forceSoftwareVideo = bool.fromEnvironment('BHE_SOFTWARE_VIDEO');

/// 播放器是否走软件渲染：Windows 上关了硬件加速。
bool useSoftwareVideo() => Platform.isWindows || _forceSoftwareVideo;

/// 播放器是否已经把画面转正。
///
/// 软件渲染下 mpv 不处理旋转，要由 [OrientedVideo] 转正（见
/// [matchPlayerToSourceRotation]）；硬件渲染交给播放器自己处理。
bool playerAppliesRotation() => !useSoftwareVideo();

/// 打开视频之前调用（播放器会在片源之间复用，每次 open 前都要调）：软件渲染下带旋转角的
/// 源让 mpv 按编码方向输出，交给 [OrientedVideo] 转正；没有旋转角时恢复 mpv 默认值。
Future<void> matchPlayerToSourceRotation(Player player, {required int rotation}) async {
  if (playerAppliesRotation()) return;
  final native = player.platform;
  if (native is! NativePlayer) return;
  await native.setProperty('video-rotate', rotationQuarterTurns(rotation) == 0 ? '0' : 'no');
}
