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
          begin: const Offset(0, -0.25),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut)),
        child: FadeTransition(
          opacity: _anim,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Spacing.md),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(CsRadius.lg),
                border: Border.all(color: c.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(width: 3, height: 36, color: color),
                  const SizedBox(width: Spacing.sm),
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.message.title,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (widget.message.description != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.message.description!,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ],
                        if (widget.message.action != null &&
                            widget.message.actionLabel != null) ...[
                          const SizedBox(height: Spacing.sm),
                          InkWell(
                            onTap: widget.message.action,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                widget.message.actionLabel!,
                                style: TextStyle(
                                  color: c.indigo,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(LucideIcons.x, size: 16, color: c.textTertiary),
                    onPressed: widget.onDismiss,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
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
