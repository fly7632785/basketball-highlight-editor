// lib/components/cs_button.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

enum CsButtonVariant { primary, secondary, ghost, danger }
enum CsButtonSize { sm, md, lg }

class CsButton extends StatelessWidget {
  const CsButton({
    required this.label,
    this.onPressed,
    this.variant = CsButtonVariant.primary,
    this.size = CsButtonSize.md,
    this.icon,
    this.isLoading = false,
    super.key,
  });

  final VoidCallback? onPressed;
  final CsButtonVariant variant;
  final CsButtonSize size;
  final IconData? icon;
  final Widget label;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final fg = _foreground(c);
    final bg = _background(c);
    final enabled = onPressed != null && !isLoading;
    final padding = _padding();
    final fontSize = size == CsButtonSize.sm ? 13.0 : 14.0;

    return _Raw(
      background: bg,
      foreground: fg,
      enabled: enabled,
      onTap: onPressed,
      child: Padding(
        padding: padding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              SizedBox(
                width: size == CsButtonSize.sm ? 14 : 16,
                height: size == CsButtonSize.sm ? 14 : 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            else if (icon != null)
              Icon(icon, size: size == CsButtonSize.sm ? 15 : 17),
            if (isLoading || icon != null) const SizedBox(width: Spacing.sm),
            DefaultTextStyle.merge(
              style: TextStyle(
                color: fg, fontSize: fontSize, fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              child: label,
            ),
          ],
        ),
      ),
    );
  }

  EdgeInsetsGeometry _padding() {
    final h = size == CsButtonSize.lg ? 20.0 : size == CsButtonSize.sm ? 12.0 : 16.0;
    final v = size == CsButtonSize.lg ? 11.0 : size == CsButtonSize.sm ? 7.0 : 9.0;
    return EdgeInsets.symmetric(horizontal: h, vertical: v);
  }

  Color _foreground(AppColors c) => switch (variant) {
    CsButtonVariant.primary || CsButtonVariant.danger => Colors.white,
    CsButtonVariant.secondary => c.textPrimary,
    CsButtonVariant.ghost => c.textSecondary,
  };
  Color _background(AppColors c) => switch (variant) {
    CsButtonVariant.primary => c.orange,
    CsButtonVariant.danger => c.error,
    CsButtonVariant.secondary => Colors.transparent,
    CsButtonVariant.ghost => Colors.transparent,
  };
}

class _Raw extends StatefulWidget {
  const _Raw({required this.child, required this.background, required this.foreground,
      required this.enabled, required this.onTap});
  final Widget child;
  final Color background, foreground;
  final bool enabled;
  final VoidCallback? onTap;
  @override
  State<_Raw> createState() => _RawState();
}

class _RawState extends State<_Raw> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Color bg = widget.background;
    Color border = Colors.transparent;
    if (widget.background == Colors.transparent) {
      // secondary / ghost
      border = widget.onTap == null ? c.border : c.borderStrong;
      if (_hover && widget.enabled) bg = c.surface2;
    } else if (_hover && widget.enabled) {
      bg = Color.alphaBlend(Colors.white.withValues(alpha: 0.10), widget.background);
    }
    final disabled = !widget.enabled;
    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: DurationD.fast,
          decoration: BoxDecoration(
            color: disabled ? c.surface3 : bg,
            borderRadius: BorderRadius.circular(CsRadius.md),
            border: border == Colors.transparent ? null : Border.all(color: border),
          ),
          foregroundDecoration: _focusRing(c),
          child: Opacity(opacity: disabled ? 0.5 : 1, child: widget.child),
        ),
      ),
    );
  }

  ShapeDecoration _focusRing(AppColors c) => ShapeDecoration(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(CsRadius.md),
      side: BorderSide(color: c.indigo.withValues(alpha: 0.0)),
    ),
  );
}
