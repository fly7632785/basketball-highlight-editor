import 'dart:async';

import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/notice_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';
import 'feedback_dialog.dart';

/// 宽屏侧边栏「反馈」和窄屏顶栏「更多」按钮，引导时高亮它们。
final feedbackSidebarKey = GlobalKey(debugLabel: 'feedback-sidebar');
final feedbackMenuKey = GlobalKey(debugLabel: 'feedback-menu');

const feedbackGuideShownKey = 'feedback_guide_shown';

/// 第一次分析完成或第一次出错时，高亮反馈入口，告诉用户有问题点哪里。
/// 每台电脑只出现一次。
class FeedbackGuideHost extends ConsumerStatefulWidget {
  const FeedbackGuideHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<FeedbackGuideHost> createState() => _FeedbackGuideHostState();
}

class _FeedbackGuideHostState extends ConsumerState<FeedbackGuideHost> {
  final _hostKey = GlobalKey();
  bool _shown = true;
  bool _visible = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) _shown = prefs.getBool(feedbackGuideShownKey) ?? false;
    });
  }

  void _maybeShow(List<NoticeMessage>? previous, List<NoticeMessage> next) {
    if (_shown) return;
    for (final m in next) {
      if (previous?.any((p) => p.id == m.id) ?? false) continue;
      final failed = m.severity == NoticeSeverity.error;
      final analysed =
          m.severity == NoticeSeverity.success && m.title.contains('分析完成');
      if (!failed && !analysed) continue;
      _shown = true;
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setBool(feedbackGuideShownKey, true),
      );
      final error = failed
          ? [m.title, m.description].whereType<String>().join('\n')
          : null;
      Timer(const Duration(milliseconds: 1200), () {
        if (mounted) {
          setState(() {
            _visible = true;
            _error = error;
          });
        }
      });
      return;
    }
  }

  void _close() => setState(() => _visible = false);

  Rect? _targetRect() {
    final host = _hostKey.currentContext?.findRenderObject() as RenderBox?;
    for (final key in [feedbackSidebarKey, feedbackMenuKey]) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (host == null || box == null || !box.attached || !box.hasSize) {
        continue;
      }
      final topLeft = box.localToGlobal(Offset.zero, ancestor: host);
      return topLeft & box.size;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<NoticeMessage>>(noticeProvider, _maybeShow);
    return Stack(
      key: _hostKey,
      children: [
        widget.child,
        if (_visible)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final target = _targetRect();
                if (target == null) return const SizedBox.shrink();
                return _GuideOverlay(
                  target: target,
                  size: constraints.biggest,
                  error: _error,
                  onClose: _close,
                  onFeedback: () {
                    _close();
                    showFeedbackDialog(context, error: _error);
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}

class _GuideOverlay extends StatelessWidget {
  const _GuideOverlay({
    required this.target,
    required this.size,
    required this.error,
    required this.onClose,
    required this.onFeedback,
  });

  final Rect target;
  final Size size;
  final String? error;
  final VoidCallback onClose;
  final VoidCallback onFeedback;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final hole = target.inflate(6);
    const cardWidth = 300.0;
    // 侧边栏在左边：卡片放右侧；顶栏按钮在右上：卡片放下方靠右。
    final besideSidebar = hole.left < size.width / 3;
    final left = besideSidebar
        ? hole.right + Spacing.md
        : (hole.right - cardWidth).clamp(Spacing.md, size.width - cardWidth);
    final top = besideSidebar
        ? (hole.center.dy - 90).clamp(Spacing.md, size.height - 200)
        : hole.bottom + Spacing.md;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            child: CustomPaint(painter: _SpotlightPainter(hole, c.orange)),
          ),
        ),
        Positioned(
          left: left.toDouble(),
          top: top.toDouble(),
          width: cardWidth,
          child: Material(
            key: const Key('feedback-guide'),
            color: c.surface,
            elevation: 8,
            borderRadius: BorderRadius.circular(CsRadius.md),
            child: Padding(
              padding: const EdgeInsets.all(Spacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.bheText(
                      error == null ? '遇到问题？点这里反馈' : '刚才出错了？点这里反馈',
                    ),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    context.bheText(
                      '点「反馈」可以一键复制诊断信息（版本、系统和运行日志），发到交流群或邮件给我，排查会快很多。',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: c.textSecondary,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: onClose,
                        child: Text(context.bheText('知道了')),
                      ),
                      const SizedBox(width: Spacing.xs),
                      FilledButton(
                        onPressed: onFeedback,
                        child: Text(context.bheText('现在反馈')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter(this.hole, this.color);

  final Rect hole;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Path()..addRect(Offset.zero & size);
    final spot = Path()
      ..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(10)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, dim, spot),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(hole, const Radius.circular(10)),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.hole != hole || old.color != color;
}
