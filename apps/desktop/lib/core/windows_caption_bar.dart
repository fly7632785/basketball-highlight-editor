import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/app_colors.dart';
import 'windows_title_bar.dart' show appTitle;

/// Windows 应用内标题栏。
///
/// 原生标题栏 + WS_THICKFRAME 在 Win10 上会在窗口左/下/右残留灰色
/// 缩放边框(DWMWA_BORDER_COLOR 仅 Win11 可用);配合 main.dart 的
/// TitleBarStyle.hidden 让客户区覆盖整个窗口后,由本组件提供可拖拽
/// 标题栏与窗口按钮,外观完全跟随应用主题。
class WindowsCaptionBar extends StatelessWidget {
  const WindowsCaptionBar({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final foreground = c.textSecondary;
    return GestureDetector(
      onDoubleTap: WindowsCaptionBar.toggleMaximize,
      child: DragToMoveArea(
        child: SizedBox(
          width: double.infinity,
          height: 36,
          child: Container(
            // 与侧栏同用 surface,标题栏和下方内容颜色无缝衔接。
            color: c.surface,
            child: Row(
              children: [
                const SizedBox(width: 14),
                Text(
                  appTitle,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
                const Spacer(),
                _CaptionButton(
                  icon: LucideIcons.minus,
                  foreground: foreground,
                  tooltip: '最小化',
                  onTap: () => windowManager.minimize(),
                ),
                _CaptionButton(
                  icon: LucideIcons.square,
                  iconSize: 12,
                  foreground: foreground,
                  tooltip: '最大化 / 还原',
                  onTap: WindowsCaptionBar.toggleMaximize,
                ),
                _CaptionButton(
                  icon: LucideIcons.x,
                  foreground: foreground,
                  tooltip: '关闭',
                  isClose: true,
                  onTap: () => windowManager.close(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.foreground,
    required this.onTap,
    this.tooltip,
    this.iconSize = 15,
    this.isClose = false,
  });

  final IconData icon;
  final Color foreground;
  final Future<void> Function() onTap;
  final String? tooltip;
  final double iconSize;
  final bool isClose;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hovering = _hovering;
    final background = widget.isClose && hovering
        ? const Color(0xFFE81123)
        : hovering
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.transparent;
    final color = widget.isClose && hovering ? Colors.white : widget.foreground;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Semantics(
          button: true,
          label: widget.tooltip,
          child: Container(
            width: 44,
            height: 36,
            color: background,
            child: Icon(widget.icon, size: widget.iconSize, color: color),
          ),
        ),
      ),
    );
  }
}
