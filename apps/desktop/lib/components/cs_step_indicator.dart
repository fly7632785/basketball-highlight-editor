// lib/components/cs_step_indicator.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

typedef CsStep = ({String index, String title, IconData icon, bool completed});

class CsStepIndicator extends StatelessWidget {
  const CsStepIndicator({required this.steps, this.direction = Axis.horizontal, super.key});
  final List<CsStep> steps;
  final Axis direction;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final children = <Widget>[];
    for (var i = 0; i < steps.length; i++) {
      children.add(_StepNode(step: steps[i]));
      if (i < steps.length - 1) {
        if (direction == Axis.horizontal) {
          children.add(Expanded(
            child: Container(height: 2, color: steps[i].completed ? c.indigo : c.border),
          ));
        } else {
          children.add(Container(
            width: 2, height: 24,
            color: steps[i].completed ? c.indigo : c.border,
          ));
        }
      }
    }
    return switch (direction) {
      Axis.horizontal => Row(crossAxisAlignment: CrossAxisAlignment.center, children: children),
      Axis.vertical => Column(crossAxisAlignment: CrossAxisAlignment.center, children: children),
    };
  }
}

class _StepNode extends StatelessWidget {
  const _StepNode({required this.step});
  final CsStep step;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (step.completed) {
      return Container(
        width: 28, height: 28,
        decoration: BoxDecoration(color: c.indigo, shape: BoxShape.circle),
        child: Icon(step.icon, size: 14, color: Colors.white),
      );
    }
    return Container(
      width: 28, height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: c.borderStrong),
      ),
      child: Text(step.index, style: TextStyle(
        color: c.indigo, fontSize: 13, fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      )),
    );
  }
}
