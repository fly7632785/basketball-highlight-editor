import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bhe_l10n/bhe_l10n.dart';

void main() {
  test('maps system locales to supported app locales', () {
    expect(BheLocale.fromSystem(const Locale('zh', 'TW')), BheLocale.zh);
    expect(BheLocale.fromSystem(const Locale('en', 'GB')), BheLocale.en);
    expect(BheLocale.fromSystem(const Locale('ja', 'JP')), BheLocale.en);
  });

  test('restores persisted locale names', () {
    expect(BheLocale.fromName('zh-CN'), BheLocale.zh);
    expect(BheLocale.fromName('en'), BheLocale.en);
    expect(BheLocale.fromName('en-US'), BheLocale.en);
    expect(BheLocale.fromName(null), BheLocale.zh);
  });

  testWidgets('translates legacy engine messages only in English', (
    tester,
  ) async {
    late BheLocalizations english;
    late BheLocalizations chinese;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: BheLocalizations.localizationsDelegates,
        supportedLocales: BheLocalizations.supportedLocales,
        locale: BheLocale.en,
        home: Builder(
          builder: (context) {
            english = BheLocalizations.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(english.text('视频解码不完整'), 'Video decoding was incomplete');
    expect(english.text('审核 2/25'), 'Review 2/25');
    expect(english.text('正在导出 3-4/25'), 'Exporting 3-4/25');
    expect(english.text('“demo”及其审核记录会从本机移除。'), contains('demo'));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: BheLocalizations.localizationsDelegates,
        supportedLocales: BheLocalizations.supportedLocales,
        locale: BheLocale.zh,
        home: Builder(
          builder: (context) {
            chinese = BheLocalizations.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(chinese.text('视频解码不完整'), '视频解码不完整');
  });

  testWidgets('translates desktop export copy and dynamic summaries', (
    tester,
  ) async {
    late BheLocalizations english;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: BheLocalizations.localizationsDelegates,
        supportedLocales: BheLocalizations.supportedLocales,
        locale: BheLocale.en,
        home: Builder(
          builder: (context) {
            english = BheLocalizations.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(
      english.text('导出会包含所有当前保留的候选；已排除片段不会进入输出。'),
      'Exports include all currently included candidates; excluded clips are not output.',
    );
    expect(
      english.text('完成一次导出后，历史记录会出现在这里。'),
      'Export something once and its history will appear here.',
    );
    expect(
      english.text('2026-09-14 12:00 · 处理 1.5 秒'),
      '2026-09-14 12:00 · Processing 1.5 sec',
    );
    expect(
      english.text('当前编辑白色篮网区域：覆盖篮圈下方到网底，尽量不要包含篮板、球员或地面。'),
      startsWith('Editing the white net region:'),
    );
    expect(
      english.text('当前编辑橙色投篮分析区域：覆盖来球轨迹、篮圈和篮网下方的落球范围。'),
      startsWith('Editing the orange shot analysis region:'),
    );
    expect(english.text('新建项目'), 'New project');
    expect(
      english.text('全部候选 · 12 个'),
      'All candidates · 12',
    );
    expect(
      english.text('标准分析 · 13 个候选 · 用时 10 秒'),
      'Standard analysis · 13 candidates · Elapsed 10 sec',
    );
    expect(
      english.text('将更新 0 个片段，保留 15 个手动调整片段。'),
      'Update 0 clips; keep 15 manually adjusted clips.',
    );
    expect(
      english.text('将覆盖全部 15 个片段，其中 15 个曾手动调整。'),
      'Overwrite all 15 clips; 15 were manually adjusted.',
    );
    expect(
      english.text('当前区域 0.40 × 0.30'),
      'Current region 0.40 × 0.30',
    );
    expect(english.text('当前 00:18'), 'Current 00:18');
    expect(english.text('投篮区'), 'Shot area');
    expect(english.text('篮网'), 'Net');
    expect(
      english.text('所选视频的分辨率或时长与项目记录不一致，请选择同一段原视频。'),
      'The selected video resolution or duration does not match the project record. Choose the same source video.',
    );
    expect(
      english.text('所选视频文件与项目记录不一致，请选择原始视频。'),
      'The selected video file does not match the project record. Choose the original video.',
    );
    expect(
      english.text('正在取消任务并关闭项目…'),
      'Cancelling active tasks and closing the project…',
    );
    expect(
      english.text('Engine 进程已退出（exitCode=1）：stderr detail'),
      'Engine process exited (exitCode=1): stderr detail',
    );
    expect(
      english.text('置信度 82%  ·  轨迹 91%  ·  穿框 100%  ·  篮网 64%'),
      'Confidence 82%  ·  Trajectory 91%  ·  Crossing 100%  ·  Net 64%',
    );
    expect(
      english.text('跳过热身或无关片段，修改会自动保存。'),
      'Skip warm-ups or unrelated clips; changes are saved automatically.',
    );
    expect(
      english.text('分析详情：代理 1 秒 · 缓存命中 3'),
      'Analysis details: Proxy 1 sec · Cache hits 3',
    );
    expect(
      english.text('未找到 Python 运行时。请设置 BHE_PYTHON，或把 Python 放入应用运行时目录。'),
      startsWith('Python runtime not found.'),
    );
  });

}
