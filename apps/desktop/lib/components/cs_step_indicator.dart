import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

typedef CsStep = ({String index, String title, IconData icon, bool completed});

class CsStepIndicator extends StatelessWidget {
  const CsStepIndicator({
    required this.steps,
    this.direction = Axis.horizontal,
    super.key,
  });

  final List<CsStep> steps;
  final Axis direction;

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) return const SizedBox.shrink();
    return direction == Axis.horizontal
        ? _HorizontalSteps(steps: steps)
        : _VerticalSteps(steps: steps);
  }
}

class _HorizontalSteps extends StatelessWidget {
  const _HorizontalSteps({required this.steps});

  final List<CsStep> steps;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < steps.length; index++)
          Expanded(
            child: Semantics(
              label:
                  '${steps[index].title}，${steps[index].completed ? '已完成' : '未完成'}',
              child: Column(
                children: [
                  SizedBox(
                    height: 28,
                    child: Row(
                      children: [
                        Expanded(
                          child: _Connector(
                            color: index == 0
                                ? Colors.transparent
                                : steps[index - 1].completed
                                ? c.indigo
                                : c.border,
                          ),
                        ),
                        _StepNode(step: steps[index]),
                        Expanded(
                          child: _Connector(
                            color: index == steps.length - 1
                                ? Colors.transparent
                                : steps[index].completed
                                ? c.indigo
                                : c.border,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    steps[index].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: steps[index].completed
                          ? c.textPrimary
                          : c.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _VerticalSteps extends StatelessWidget {
  const _VerticalSteps({required this.steps});

  final List<CsStep> steps;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      children: [
        for (var index = 0; index < steps.length; index++) ...[
          Semantics(
            label:
                '${steps[index].title}，${steps[index].completed ? '已完成' : '未完成'}',
            child: Row(
              children: [
                _StepNode(step: steps[index]),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    steps[index].title,
                    style: TextStyle(
                      color: steps[index].completed
                          ? c.textPrimary
                          : c.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (index < steps.length - 1)
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 2,
                height: 20,
                margin: const EdgeInsets.only(left: 13),
                color: steps[index].completed ? c.indigo : c.border,
              ),
            ),
        ],
      ],
    );
  }
}

class _Connector extends StatelessWidget {
  const _Connector({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(height: 1.5, color: color);
}

class _StepNode extends StatelessWidget {
  const _StepNode({required this.step});

  final CsStep step;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    if (step.completed) {
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(color: c.indigo, shape: BoxShape.circle),
        child: Icon(step.icon, size: 14, color: Colors.white),
      );
    }
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: c.borderStrong),
      ),
      child: Text(
        step.index,
        style: TextStyle(
          color: c.indigo,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
