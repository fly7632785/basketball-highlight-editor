// lib/components/cs_skeleton.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsSkeleton extends StatefulWidget {
  const CsSkeleton({required this.width, required this.height, super.key});
  final double width;
  final double height;

  @override
  State<CsSkeleton> createState() => _CsSkeletonState();
}

class _CsSkeletonState extends State<CsSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
      reverseDuration: const Duration(milliseconds: 200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (MediaQuery.disableAnimationsOf(context)) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(CsRadius.sm),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(CsRadius.sm),
          gradient: LinearGradient(
            colors: [c.surface2, c.surface3, c.surface2],
            stops: [0.0, _controller.value, 1.0],
          ),
        ),
      ),
    );
  }
}
