import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/core/app_diagnostics.dart';

void main() {
  group('mpvLocationFor', () {
    test('Windows UNC 反斜杠路径原样直传,不走 Uri.file', () {
      expect(
        mpvLocationFor(r'\\test-server\测试共享文件夹\sample.mp4', isWindows: true),
        r'\\test-server\测试共享文件夹\sample.mp4',
      );
    });

    test('Windows UNC 正斜杠路径也原样直传', () {
      expect(
        mpvLocationFor('//test-server/测试共享文件夹/sample.mp4', isWindows: true),
        '//test-server/测试共享文件夹/sample.mp4',
      );
    });

    test('Windows 盘符路径维持 file:// URI(本地视频验证过的形式)', () {
      expect(
        mpvLocationFor(r'C:\fixture\视频\比赛.mp4', isWindows: true),
        Uri.file(r'C:\fixture\视频\比赛.mp4').toString(),
      );
    });

    test('非 Windows 平台一律走 Uri.file', () {
      expect(
        mpvLocationFor('//test-server/nas/sample.mp4', isWindows: false),
        Uri.file('//test-server/nas/sample.mp4').toString(),
      );
    });

    test('回归:旧逻辑对 UNC 的产物是 mpv 打不开的 file://主机名 形式', () {
      // 固化根因(用随包 libmpv 实测):Uri.file 把 UNC 转成
      // file://server/share/...,mpv 的 file:// 协议不支持网络主机名,
      // loadfile 后直接 idle、无报错、无元数据 → 黑屏。
      expect(
        Uri.file(r'\\test-server\nas\sample.mp4', windows: true).toString(),
        'file://test-server/nas/sample.mp4',
      );
    });
  });
}
