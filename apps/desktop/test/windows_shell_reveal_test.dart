import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/core/windows_shell_reveal.dart';

void main() {
  group('normalizeWindowsShellPath', () {
    test('正斜杠全部替换为反斜杠', () {
      expect(
        normalizeWindowsShellPath('C:/Users/Jafir/exports'),
        r'C:\Users\Jafir\exports',
      );
    });

    test('反斜杠路径保持不变', () {
      expect(normalizeWindowsShellPath(r'C:\Users\Jafir'), r'C:\Users\Jafir');
    });

    test('UNC 正斜杠前缀正确转换', () {
      expect(
        normalizeWindowsShellPath('//nas/share/clip.mp4'),
        r'\\nas\share\clip.mp4',
      );
    });

    test('混合分隔符归一化', () {
      expect(
        normalizeWindowsShellPath(r'C:\mixed/path\to'),
        r'C:\mixed\path\to',
      );
    });

    test('中文路径内容不变,仅分隔符转换', () {
      expect(
        normalizeWindowsShellPath('D:/集锦/导出/第1段.mp4'),
        r'D:\集锦\导出\第1段.mp4',
      );
    });
  });
}
