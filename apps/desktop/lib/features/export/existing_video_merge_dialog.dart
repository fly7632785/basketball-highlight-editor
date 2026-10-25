import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../components/cs_button.dart';
import '../../core/engine_session.dart';
import '../../providers/export_output_picker.dart';
import '../../providers/session_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

class ExistingVideoMergeDialog extends ConsumerStatefulWidget {
  const ExistingVideoMergeDialog({super.key, this.picker, this.onMerge});

  final ExportOutputPicker? picker;
  final Future<void> Function(List<String> inputs, String output)? onMerge;

  @override
  ConsumerState<ExistingVideoMergeDialog> createState() =>
      _ExistingVideoMergeDialogState();
}

class _ExistingVideoMergeDialogState
    extends ConsumerState<ExistingVideoMergeDialog> {
  final List<String> _inputPaths = <String>[];
  String? _outputPath;
  String? _error;
  bool _running = false;

  bool get _canMerge =>
      !_running && _inputPaths.isNotEmpty && _outputPath != null;

  ExportOutputPicker get _picker =>
      widget.picker ?? ref.read(exportOutputPickerProvider);

  Future<void> _chooseVideos() async {
    final paths = await _picker.existingVideos(typeLabel: '视频');
    if (!mounted || paths.isEmpty) return;
    setState(() {
      _inputPaths.addAll(paths.where((path) => !_inputPaths.contains(path)));
      _error = null;
    });
  }

  Future<void> _chooseOutput() async {
    final path = await _picker.existingVideosMergedPath(typeLabel: '视频');
    if (!mounted || path == null) return;
    setState(() {
      _outputPath = path;
      _error = null;
    });
  }

  void _move(int from, int to) {
    setState(() {
      final path = _inputPaths.removeAt(from);
      _inputPaths.insert(to, path);
    });
  }

  Future<void> _merge() async {
    if (!_canMerge) return;
    final output = _outputPath!;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final action = widget.onMerge;
      if (action != null) {
        await action(List<String>.of(_inputPaths), output);
      } else {
        await ref.read(engineBootstrapProvider.notifier).ensure();
        await EngineSession(
          ref.read(engineClientProvider),
        ).mergeExistingVideos(inputPaths: _inputPaths, outputPath: output);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = '合并失败：$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('合并已有视频', style: theme.textTheme.titleLarge),
              const SizedBox(height: Spacing.xs),
              Text(
                '选择已导出的本地视频，可调整顺序后合并为一个 MP4。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(height: Spacing.md),
              Wrap(
                spacing: Spacing.sm,
                children: [
                  CsButton(
                    label: const Text('选择视频'),
                    icon: LucideIcons.plus,
                    variant: CsButtonVariant.secondary,
                    onPressed: _running ? null : _chooseVideos,
                  ),
                  CsButton(
                    label: const Text('选择保存位置'),
                    icon: LucideIcons.folderOutput,
                    variant: CsButtonVariant.secondary,
                    onPressed: _running ? null : _chooseOutput,
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              if (_inputPaths.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      '还没有选择视频',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.separated(
                    itemCount: _inputPaths.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: Spacing.xs),
                    itemBuilder: (context, index) {
                      final path = _inputPaths[index];
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          color: c.surface2,
                          borderRadius: BorderRadius.circular(CsRadius.sm),
                        ),
                        child: ListTile(
                          dense: true,
                          leading: Text('${index + 1}'),
                          title: Text(_fileName(path)),
                          subtitle: Text(
                            path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Wrap(
                            spacing: 0,
                            children: [
                              IconButton(
                                key: Key('existing-video-up-$index'),
                                tooltip: '上移',
                                onPressed: _running || index == 0
                                    ? null
                                    : () => _move(index, index - 1),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                key: Key('existing-video-down-$index'),
                                tooltip: '下移',
                                onPressed:
                                    _running || index == _inputPaths.length - 1
                                    ? null
                                    : () => _move(index, index + 1),
                                icon: const Icon(Icons.arrow_downward),
                              ),
                              IconButton(
                                tooltip: '移除',
                                onPressed: _running
                                    ? null
                                    : () => setState(
                                        () => _inputPaths.removeAt(index),
                                      ),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              if (_outputPath != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  '输出：$_outputPath',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(color: c.error),
                ),
              ],
              const SizedBox(height: Spacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  CsButton(
                    label: const Text('取消'),
                    variant: CsButtonVariant.ghost,
                    onPressed: _running
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: Spacing.sm),
                  CsButton(
                    key: const Key('existing-video-merge-start'),
                    label: const Text('合并并导出'),
                    icon: LucideIcons.merge,
                    isLoading: _running,
                    onPressed: _canMerge ? _merge : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _fileName(String path) => path.replaceAll('\\', '/').split('/').last;
