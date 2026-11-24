part of '../../mobile_ui.dart';

Future<void> _showProjectInfo(
  BuildContext context,
  MobileAppState state,
  ProjectSnapshot project,
) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => _ProjectInfoPage(state: state, snapshot: project),
  ),
);

class _ProjectInfoPage extends StatefulWidget {
  const _ProjectInfoPage({required this.state, required this.snapshot});

  final MobileAppState state;
  final ProjectSnapshot snapshot;

  @override
  State<_ProjectInfoPage> createState() => _ProjectInfoPageState();
}

class _ProjectInfoPageState extends State<_ProjectInfoPage> {
  late String name = widget.snapshot.name;
  late final video = widget.snapshot.video;
  late final metadata = video == null
      ? null
      : readProjectVideoMetadata(video!.path);

  @override
  Widget build(BuildContext context) {
    final project = widget.snapshot;
    final unknown = context.bheText('未知');
    final localizations = MaterialLocalizations.of(context);
    String date(DateTime? value) {
      if (value == null) return unknown;
      final local = value.toLocal();
      return '${localizations.formatFullDate(local)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.bheText('项目信息'))),
      body: FutureBuilder(
        future: metadata,
        builder: (context, snapshot) {
          final capture = video?.capturedAt ?? snapshot.data?.capturedAt;
          final fps = video?.frameRate ?? snapshot.data?.frameRate;
          final codec = video?.codec ?? snapshot.data?.codec;
          final ext = video?.name.split('.').last.toUpperCase();
          final format = switch (codec) {
            'video/dolby-vision' => context.bheText('杜比视界'),
            'video/hevc' => 'HEVC',
            'video/avc' => 'H.264',
            null => ext ?? unknown,
            _ => codec,
          };
          final seconds = (video?.durationMs ?? 0) ~/ 1000;
          final duration = [
            seconds ~/ 3600,
            (seconds ~/ 60) % 60,
            seconds % 60,
          ].map((v) => v.toString().padLeft(2, '0')).join(':');
          Widget field(String label, String value) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.bheText(label),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                SelectableText(value),
              ],
            ),
          );
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(child: field('项目名称', name)),
                  TextButton(
                    onPressed: () async {
                      if (!_canManageProjects(context, widget.state)) return;
                      final value = await showDialog<String>(
                        context: context,
                        builder: (_) => _ProjectRenameDialog(name: name),
                      );
                      if (value == null || !context.mounted) return;
                      final saved = await widget.state.renameManagedProject(
                        project.id,
                        value,
                      );
                      if (!context.mounted) return;
                      if (saved) {
                        setState(() => name = value.trim());
                      } else {
                        _projectActionFailed(context, widget.state);
                      }
                    },
                    child: Text(context.bheText('重命名')),
                  ),
                ],
              ),
              field('原视频文件名', video?.name ?? unknown),
              field('拍摄时间', date(capture)),
              field('时长', video == null ? unknown : duration),
              field(
                '分辨率 / 帧率',
                video == null
                    ? unknown
                    : '${video!.width} × ${video!.height} / ${fps == null ? unknown : '${fps.toStringAsFixed(2)} fps'}',
              ),
              field('视频格式', format),
              field(
                '文件大小',
                video == null
                    ? unknown
                    : '${(video!.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
              ),
              field('所在位置', video?.path ?? unknown),
              field('分析时间', date(project.lastAnalysisAt)),
              field('候选数', '${project.candidates.length}'),
            ],
          );
        },
      ),
    );
  }
}

class _ProjectNameText extends StatelessWidget {
  const _ProjectNameText(this.name, {this.style});
  final String name;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textStyle = DefaultTextStyle.of(context).style.merge(style);
      final painter = TextPainter(
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      );
      bool fits(String text) {
        painter.text = TextSpan(text: text, style: textStyle);
        painter.layout();
        return painter.width <= constraints.maxWidth;
      }

      var label = name;
      if (!fits(label)) {
        final chars = name.characters.toList();
        var min = 0;
        var max = chars.length - 1;
        String shorten(int count) =>
            '${chars.take((count + 1) ~/ 2).join()}…${chars.skip(chars.length - count ~/ 2).join()}';
        while (min < max) {
          final mid = (min + max + 1) ~/ 2;
          if (fits(shorten(mid))) {
            min = mid;
          } else {
            max = mid - 1;
          }
        }
        label = shorten(min);
      }
      painter.dispose();
      return Text(label, semanticsLabel: name, style: textStyle, maxLines: 1);
    },
  );
}
