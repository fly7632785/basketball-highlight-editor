import 'package:desktop/core/windows_shell_reveal.dart';

void main(List<String> args) {
  final mode = args.isNotEmpty ? args[0] : 'select';
  if (mode == 'select') {
    openInWindowsExplorer(directory: r'D:\', select: r'D:\zhao.mp4');
  } else {
    openInWindowsExplorer(directory: r'D:\冒烟测试导出(可删)');
  }
}
