import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bhe_l10n/bhe_l10n.dart';

import '../core/video_orientation.dart';
import '../providers/onboarding_provider.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';
import 'cs_button.dart';

/// 引导的一步：高亮 [target] 所在区域并显示一句话；[target] 为空时气泡居中。
/// 文案是中文原文，显示时经 `bheText` 翻译。
class OnboardingStep {
  const OnboardingStep({
    required this.id,
    required this.title,
    required this.body,
    this.target,
    this.extra,
    this.extraHeight = 0,
    this.width,
    this.reserveBottom = 0,
    this.sidePanel = false,
  });

  /// 登记在 `onboardingStepIds` 里的步骤 id，“看过”按它记。
  final String id;
  final String title;
  final String body;
  final GlobalKey? target;

  /// 正文下面附带的内容（例如示例图），[extraHeight] 用来给气泡留出位置。
  final WidgetBuilder? extra;
  final double extraHeight;
  final double? width;
  final double reserveBottom;
  final bool sidePanel;
}

/// 包住一个页面：首次进入（或点“?”）时在页面上盖一层遮罩 + 气泡，逐步介绍。
///
/// 遮罩只是 Flutter 层的半透明盖板，不碰播放器；[hideVideo] 为真时引导期间把视频画面
/// 换成黑色占位（和选择保存位置前同一个做法）。目标控件当前不存在的步骤会被跳过。
class OnboardingGuide extends ConsumerStatefulWidget {
  const OnboardingGuide({
    super.key,
    required this.page,
    required this.steps,
    required this.child,
    this.ready = true,
    this.hideVideo = false,
    this.onFinished,
  });

  final String page;
  final List<OnboardingStep> steps;
  final Widget child;

  /// 页面里要讲的东西是否已经出现（例如审核页要有候选）。
  final bool ready;
  final bool hideVideo;
  final VoidCallback? onFinished;

  @override
  ConsumerState<OnboardingGuide> createState() => _OnboardingGuideState();
}

class _OnboardingGuideState extends ConsumerState<OnboardingGuide> {
  List<OnboardingStep> _active = const [];
  int _index = 0;
  bool _dismissedThisSession = false;
  int _lastReplay = 0;
  int _lastResets = 0;
  Rect? _lastRect;

  bool get _showing => _active.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _lastReplay = ref.read(onboardingProvider).replay[widget.page] ?? 0;
    _lastResets = ref.read(onboardingProvider).resets;
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面被切走（保活在后台）时收起引导并交还视频画面，不记为看过，回来再弹。
    if (_showing && !TickerMode.valuesOf(context).enabled) {
      _active = const [];
      _setVideoHidden(false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
  }

  @override
  void didUpdateWidget(covariant OnboardingGuide oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
  }

  @override
  void dispose() {
    _setVideoHidden(false);
    super.dispose();
  }

  VoidCallback? _releaseVideo;

  void _setVideoHidden(bool hidden) {
    if (!widget.hideVideo) return;
    if (hidden) {
      _releaseVideo ??= holdVideoSurfaceHidden();
    } else {
      _releaseVideo?.call();
      _releaseVideo = null;
    }
  }

  /// 页面在前台、内容就绪，并且是首次或被要求重看时开始。
  void _maybeStart({bool force = false}) {
    if (!mounted || _showing) return;
    if (!widget.ready || !TickerMode.valuesOf(context).enabled) return;
    final onboarding = ref.read(onboardingProvider);
    if (onboarding.resets != _lastResets) {
      // 点过「重置新手引导」：这个页面（可能一直保活在后台）也要能再弹。
      _lastResets = onboarding.resets;
      _dismissedThisSession = false;
    }
    final replay = onboarding.replay[widget.page] ?? 0;
    final replayRequested = replay != _lastReplay;
    // 首次（或升级后出现新步骤）只弹没看过的；点“?”重看则从头走全部。
    final unseen = [
      for (final step in widget.steps)
        if (!onboarding.seen.contains(step.id)) step,
    ];
    final firstTime =
        onboarding.loaded && unseen.isNotEmpty && !_dismissedThisSession;
    if (!force && !replayRequested && !firstTime) return;
    _lastReplay = replay;
    final steps = [
      for (final step in replayRequested ? widget.steps : unseen)
        if (step.target == null || step.target!.currentContext != null) step,
    ];
    if (steps.isEmpty) return;
    setState(() {
      _active = steps;
      _index = 0;
    });
    _setVideoHidden(true);
    _revealTarget();
  }

  /// 目标在滚动区域外时先滚到可见处，再按新位置画遮罩。
  void _revealTarget() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showing) return;
      final targetContext = _active[_index].target?.currentContext;
      if (targetContext != null && targetContext.mounted) {
        Scrollable.ensureVisible(
          targetContext,
          alignment: _active[_index].sidePanel ? 1.0 : 0.3,
          duration: Duration.zero,
        );
      }
      setState(() {});
    });
  }

  void _finish() {
    _dismissedThisSession = true;
    final shown = [for (final step in _active) step.id];
    setState(() => _active = const []);
    _setVideoHidden(false);
    unawaited(ref.read(onboardingProvider.notifier).markSeen(shown));
    widget.onFinished?.call();
  }

  void _next() {
    if (_index >= _active.length - 1) {
      _finish();
    } else {
      setState(() => _index++);
      _revealTarget();
    }
  }

  void _previous() {
    if (_index > 0) {
      setState(() => _index--);
      _revealTarget();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<OnboardingState>(onboardingProvider, (previous, next) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
    });
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Padding(
          padding: EdgeInsets.only(
            bottom: _showing
                ? math.min(_active[_index].reserveBottom, math.max(0, MediaQuery.sizeOf(context).height - 400))
                : 0,
          ),
          child: _showing && _active[_index].sidePanel
              ? Transform.scale(scale: 0.62, alignment: Alignment.topLeft, child: widget.child)
              : widget.child,
        ),
        if (_showing)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => _buildOverlay(
                context,
                Size(constraints.maxWidth, constraints.maxHeight),
              ),
            ),
          ),
      ],
    );
  }

  Rect? _targetRect(OnboardingStep step) {
    final targetContext = step.target?.currentContext;
    final overlay = context.findRenderObject();
    if (targetContext == null || overlay is! RenderBox) return null;
    final box = targetContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    var rect = MatrixUtils.transformRect(
      box.getTransformTo(overlay), Offset.zero & box.size,
    );
    // 目标比可见的滚动区域还高（或还宽）时，只高亮看得见的那一部分，
    // 不然高亮框会伸到滚动区域外面的步骤条、底部按钮上。
    final scrollable = Scrollable.maybeOf(targetContext);
    final viewport = scrollable?.context.findRenderObject();
    if (viewport is RenderBox && viewport.hasSize && viewport.attached) {
      final visible = MatrixUtils.transformRect(
        viewport.getTransformTo(overlay), Offset.zero & viewport.size,
      );
      rect = rect.intersect(visible);
    }
    return rect.isEmpty ? null : rect;
  }

  Widget _buildOverlay(BuildContext context, Size size) {
    final step = _active[_index];
    final c = AppColors.of(context);
    final rect = _targetRect(step)?.inflate(6);
    if (rect != _lastRect) {
      _lastRect = rect;
      // 窗口缩放后目标位置变了，下一帧再按新位置画一次。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showing) setState(() {});
      });
    }
    final bodyLines = '\n'.allMatches(step.body).length + 1;
    final bubbleWidth = step.width ?? (step.extra != null
        ? 560.0
        : bodyLines > 1
        ? 440.0
        : 340.0);
    final bubbleHeight = 170.0 + (bodyLines - 1) * 24 + step.extraHeight;
    double left;
    double top;
    if (step.sidePanel) {
      left = size.width - bubbleWidth - 12;
      top = 12;
    } else if (rect == null) {
      left = (size.width - bubbleWidth) / 2;
      top = (size.height - bubbleHeight) / 2;
    } else {
      left = rect.left.clamp(12.0, math.max(12.0, size.width - bubbleWidth - 12));
      if (rect.bottom + 12 + bubbleHeight <= size.height) {
        top = rect.bottom + 12;
      } else if (rect.top - 12 - bubbleHeight >= 0) {
        top = rect.top - 12 - bubbleHeight;
      } else {
        // 目标又高又宽（例如视频区）：气泡压在它里面靠下的位置。
        top = size.height - bubbleHeight - 24;
        left = (size.width - bubbleWidth) / 2;
      }
    }
    final last = _index == _active.length - 1;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _finish},
      child: Focus(
        autofocus: true,
        child: Stack(
          key: const Key('onboarding-overlay'),
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: CustomPaint(
                  painter: _ScrimPainter(rect: rect, color: const Color(0xB3000000)),
                ),
              ),
            ),
            Positioned(
              left: left.clamp(0.0, math.max(0.0, size.width - math.min(bubbleWidth, size.width - 24))),
              top: top.clamp(12.0, math.max(12.0, size.height - 12 - math.min(bubbleHeight, size.height - 24))),
              width: math.min(bubbleWidth, size.width - 24),
              // 窗口小或文字多时气泡不超出屏幕，内容在气泡里滚动。
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: math.max(120.0, size.height - 24)),
                child: Material(
                color: c.surface,
                elevation: 8,
                borderRadius: BorderRadius.circular(CsRadius.md),
                child: Container(
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(CsRadius.md),
                    border: Border.all(color: c.orange),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 文字和示例图放在可滚动区里，「跳过 / 上一步 / 下一步」始终固定在底部。
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.bheText(step.title),
                                key: const Key('onboarding-title'),
                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  color: c.textPrimary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: Spacing.xs),
                              Text(
                                context.bheText(step.body),
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: c.textSecondary,
                                ),
                              ),
                              if (step.extra != null) ...[
                                const SizedBox(height: Spacing.sm),
                                step.extra!(context),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: Spacing.md),
                      Row(
                        children: [
                          Text(
                            '${_index + 1}/${_active.length}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: c.textTertiary),
                          ),
                          const Spacer(),
                          CsButton(
                            key: const Key('onboarding-skip'),
                            label: Text(context.bheText('跳过')),
                            variant: CsButtonVariant.ghost,
                            size: CsButtonSize.sm,
                            onPressed: _finish,
                          ),
                          if (_index > 0) ...[
                            const SizedBox(width: Spacing.xs),
                            CsButton(
                              key: const Key('onboarding-previous'),
                              label: Text(context.bheText('上一步')),
                              variant: CsButtonVariant.secondary,
                              size: CsButtonSize.sm,
                              onPressed: _previous,
                            ),
                          ],
                          const SizedBox(width: Spacing.xs),
                          CsButton(
                            key: const Key('onboarding-next'),
                            label: Text(
                              context.bheText(last ? '完成' : '下一步'),
                            ),
                            size: CsButtonSize.sm,
                            onPressed: _next,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScrimPainter extends CustomPainter {
  _ScrimPainter({required this.rect, required this.color});

  final Rect? rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRect(Offset.zero & size);
    final hole = rect;
    if (hole != null) {
      path.addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(10)));
      path.fillType = PathFillType.evenOdd;
    }
    canvas.drawPath(path, Paint()..color = color);
    if (hole != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(hole, const Radius.circular(10)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFF08C00),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ScrimPainter old) =>
      old.rect != rect || old.color != color;
}
