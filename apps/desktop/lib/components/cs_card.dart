// lib/components/cs_card.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

enum CsCardTier { defaultTier, hover, selected }

class CsCard extends StatelessWidget {
  const CsCard({
    required this.child,
    this.tier = CsCardTier.defaultTier,
    this.onTap,
    this.padding = const EdgeInsets.all(Spacing.lg),
    this.selectedAccent = false,
    this.accentColor,
    super.key,
  });
  final Widget child;
  final CsCardTier tier;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final bool selectedAccent;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final base = switch (tier) {
      CsCardTier.defaultTier => c.surface,
      CsCardTier.hover => c.surface2,
      CsCardTier.selected => c.surface3,
    };
    return _CardBox(
      color: base,
      border: c.border,
      accent: selectedAccent ? (accentColor ?? c.indigo) : null,
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    );
  }
}

class _CardBox extends StatefulWidget {
  const _CardBox({required this.child, required this.color, required this.border,
      this.accent, this.onTap});
  final Widget child;
  final Color color, border;
  final Color? accent;
  final VoidCallback? onTap;
  @override
  State<_CardBox> createState() => _CardBoxState();
}

class _CardBoxState extends State<_CardBox> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null;
    Color bg = widget.color;
    if (interactive && _hover) bg = Color.alphaBlend(Colors.white.withValues(alpha: 0.04), bg);
    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: interactive ? (_) => setState(() => _hover = true) : null,
      onExit: interactive ? (_) => setState(() => _hover = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DurationD.fast,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(CsRadius.lg),
            border: Border.all(color: widget.border),
          ),
          child: IntrinsicWidth(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.accent != null)
                  Container(width: 3, color: widget.accent),
                Flexible(child: widget.child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
