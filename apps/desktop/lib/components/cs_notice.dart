// lib/components/cs_notice.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../providers/notice_provider.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsNotice extends StatefulWidget {
  const CsNotice({required this.message, required this.onDismiss, super.key});
  final NoticeMessage message;
  final VoidCallback onDismiss;

  @override
  State<CsNotice> createState() => _CsNoticeState();
}

class _CsNoticeState extends State<CsNotice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  Timer? _timer;

  Duration get _effectiveDuration =>
      widget.message.severity == NoticeSeverity.error
      ? const Duration(seconds: 6)
      : widget.message.duration;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: DurationD.normal)
      ..forward();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(_effectiveDuration, widget.onDismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (color, icon) = switch (widget.message.severity) {
      NoticeSeverity.success => (c.success, LucideIcons.circleCheck),
      NoticeSeverity.error => (c.error, LucideIcons.circleX),
      NoticeSeverity.warning => (c.warning, LucideIcons.triangleAlert),
      NoticeSeverity.info => (c.indigo, LucideIcons.info),
    };
    return MouseRegion(
      onEnter: (_) => _timer?.cancel(),
      onExit: (_) => _startTimer(),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.16),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic)),
        child: FadeTransition(
          opacity: _anim,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: c.surface.withValues(alpha: 0.97),
                borderRadius: BorderRadius.circular(CsRadius.md),
                border: Border.all(color: color.withValues(alpha: 0.38)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: color),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.message.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (widget.message.description != null)
                          Text(
                            widget.message.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 11,
                              height: 1.35,
                            ),
                          ),
                        if (widget.message.action != null &&
                            widget.message.actionLabel != null)
                          InkWell(
                            onTap: widget.message.action,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                widget.message.actionLabel!,
                                style: TextStyle(
                                  color: c.indigo,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  Semantics(
                    button: true,
                    label: '关闭提示',
                    child: IconButton(
                      icon: Icon(
                        LucideIcons.x,
                        size: 14,
                        color: c.textTertiary,
                      ),
                      onPressed: widget.onDismiss,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 22,
                        minHeight: 22,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
