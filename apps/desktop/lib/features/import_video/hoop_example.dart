import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';

import '../../components/cs_button.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

/// 检测区域的示意图（本地绘制，脚本见 scripts/make_hoop_examples.py）。
enum HoopExample {
  good('assets/hoop_example/good.png', '正确：橙色框盖住来球轨迹、篮圈和网下落球范围，白色虚线框只盖篮网'),
  tooBig('assets/hoop_example/too_big.png', '太大：别把整块篮板、球员和地面框进去'),
  tooSmall('assets/hoop_example/too_small.png', '太小：只框篮圈，球一靠近或落下就出框'),
  netGood('assets/hoop_example/net_good.png', '正确：白色框只覆盖篮网摆动范围'),
  netTooBig('assets/hoop_example/net_too_big.png', '太大：别把篮板、球员或地面框进去'),
  netTooSmall('assets/hoop_example/net_too_small.png', '太小：只框网口，漏掉网底的摆动');

  const HoopExample(this.asset, this.caption);

  final String asset;

  /// 中文原文，显示时经 `bheText` 翻译。
  final String caption;
}

const shotExamples = [
  HoopExample.good,
  HoopExample.tooBig,
  HoopExample.tooSmall,
];
const netExamples = [
  HoopExample.netGood,
  HoopExample.netTooBig,
  HoopExample.netTooSmall,
];

class HoopExampleGallery extends StatelessWidget {
  const HoopExampleGallery({
    super.key,
    this.examples = shotExamples,
    this.maxPanelWidth = 220,
  });

  final List<HoopExample> examples;
  final double maxPanelWidth;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, example) in examples.indexed) ...[
          if (index > 0) const SizedBox(width: Spacing.sm),
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxPanelWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(CsRadius.sm),
                    child: Image.asset(
                      example.asset,
                      key: ValueKey('hoop-example-${example.name}'),
                      fit: BoxFit.cover,
                      semanticLabel: context.bheText(example.caption),
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    context.bheText(example.caption),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

Future<void> showHoopExampleDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('hoop-example-dialog'),
      title: Text(context.bheText('框选示例')),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.bheText('投篮分析区（橙色）')),
              const SizedBox(height: Spacing.sm),
              const HoopExampleGallery(maxPanelWidth: 230),
              const SizedBox(height: Spacing.md),
              Text(context.bheText('篮网检测区（白色）')),
              const SizedBox(height: Spacing.sm),
              const HoopExampleGallery(
                examples: netExamples,
                maxPanelWidth: 230,
              ),
              const SizedBox(height: Spacing.md),
              Text(
                context.bheText(
                  '橙色区域用来跟踪球：从球进入篮圈上方，到落出篮网下方。白色区域只盖篮网摆动范围，用来判断球有没有穿网。系统会先自动识别，不准再拖动或缩放。',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        CsButton(
          label: Text(context.bheText('关闭')),
          variant: CsButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );
}
