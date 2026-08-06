import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    required this.videoPath,
    required this.job,
    required this.candidates,
    required this.busy,
    required this.onCancelAnalysis,
    required this.onRetryAnalysis,
    required this.onExport,
    required this.onReviewCandidate,
    required this.onUpdateClipRange,
    super.key,
  });

  final String? videoPath;
  final Map<String, dynamic>? job;
  final List<Map<String, dynamic>> candidates;
  final bool busy;
  final Future<void> Function() onCancelAnalysis;
  final Future<void> Function() onRetryAnalysis;
  final VoidCallback onExport;
  final Future<void> Function(String, String) onReviewCandidate;
  final Future<void> Function(String, int, int) onUpdateClipRange;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final state = job?['state']?.toString() ?? '未开始';
    final progress = (job?['progress'] as num?)?.toDouble() ?? 0;
    final stage = job?['stage']?.toString() ?? '';
    final analyzing = state == 'queued' || state == 'running';
    final narrow = MediaQuery.sizeOf(context).width < 1050;
    final selectedCandidate =
        widget.candidates.isEmpty || _selectedIndex >= widget.candidates.length
        ? null
        : widget.candidates[_selectedIndex];
    final preview = _PreviewPanel(
      videoPath: widget.videoPath,
      jobState: state,
      progress: progress,
      candidate: selectedCandidate,
      hasPrevious: _selectedIndex > 0,
      hasNext: _selectedIndex < widget.candidates.length - 1,
      onPrevious: () => setState(() => _selectedIndex--),
      onNext: () => setState(() => _selectedIndex++),
      onCancel: widget.onCancelAnalysis,
      recoverable: job?['recoverable'] == true,
      onRetry: widget.busy ? null : widget.onRetryAnalysis,
    );
    final queue = _QueuePanel(
      candidates: widget.candidates,
      selectedIndex: _selectedIndex,
      busy: widget.busy,
      onSelected: (index) => setState(() => _selectedIndex = index),
      onReview: widget.onReviewCandidate,
      onUpdateRange: widget.onUpdateClipRange,
      onExport: widget.onExport,
      analyzing: analyzing,
    );
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          if (job != null && (analyzing || state == 'failed')) ...[
            _AnalysisStatusCard(
              state: state,
              stage: stage,
              progress: progress,
              errorMessage: job['error_message']?.toString(),
              onCancel: analyzing ? widget.onCancelAnalysis : null,
              onRetry: state == 'failed' ? widget.onRetryAnalysis : null,
            ),
            const SizedBox(height: 16),
          ],
          Expanded(
            child: narrow
                ? Column(
                    children: [
                      Expanded(child: preview),
                      const SizedBox(height: 16),
                      SizedBox(height: 380, child: queue),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: preview),
                      const SizedBox(width: 16),
                      SizedBox(width: 390, child: queue),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _AnalysisStatusCard extends StatelessWidget {
  const _AnalysisStatusCard({
    required this.state,
    required this.stage,
    required this.progress,
    required this.errorMessage,
    required this.onCancel,
    required this.onRetry,
  });

  final String state;
  final String stage;
  final double progress;
  final String? errorMessage;
  final Future<void> Function()? onCancel;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = state == 'failed';
    final value = progress.clamp(0.0, 1.0).toDouble();
    return Card(
      color: failed ? scheme.errorContainer : scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Icon(
              failed ? Icons.error_outline : Icons.auto_awesome,
              color: failed
                  ? scheme.onErrorContainer
                  : scheme.onPrimaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failed ? '分析失败' : '正在分析视频',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: failed
                          ? scheme.onErrorContainer
                          : scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    failed
                        ? (errorMessage ?? '请检查视频、ROI 和本地运行时后重试')
                        : '${_stageLabel(stage)} · ${(value * 100).round()}%',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: failed
                          ? scheme.onErrorContainer
                          : scheme.onPrimaryContainer,
                    ),
                  ),
                  if (!failed) ...[
                    const SizedBox(height: 9),
                    LinearProgressIndicator(
                      value: value == 0 ? null : value,
                      minHeight: 6,
                      backgroundColor: scheme.onPrimaryContainer.withValues(
                        alpha: .18,
                      ),
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (onCancel != null)
              OutlinedButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('取消'),
              ),
            if (onRetry != null)
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
          ],
        ),
      ),
    );
  }
}

String _stageLabel(String stage) {
  const labels = <String, String>{
    'validate_input': '检查视频输入',
    'prepare_proxy': '生成低清代理',
    'coarse_scan': '快速扫描候选',
    'refine_candidates': '精细分析候选',
    'persist_candidates': '整理审核片段',
    'analysis': '分析视频',
  };
  return labels[stage] ?? (stage.isEmpty ? '准备中' : stage);
}

class _PreviewPanel extends StatefulWidget {
  const _PreviewPanel({
    required this.videoPath,
    required this.jobState,
    required this.progress,
    required this.candidate,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
    required this.onCancel,
    required this.recoverable,
    required this.onRetry,
  });
  final String? videoPath;
  final String jobState;
  final double progress;
  final Map<String, dynamic>? candidate;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function() onCancel;
  final bool recoverable;
  final Future<void> Function()? onRetry;

  @override
  State<_PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<_PreviewPanel> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  Duration? _clipEnd;
  String? _playerError;
  bool _clipPlaying = false;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
    unawaited(_loadVideo(widget.videoPath));
  }

  @override
  void didUpdateWidget(covariant _PreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _initializePlayer();
      unawaited(_loadVideo(widget.videoPath));
    } else if (_candidateTime(oldWidget.candidate) !=
        _candidateTime(widget.candidate)) {
      unawaited(_seekToCandidate(widget.candidate));
    }
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    final player = _player;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  void _initializePlayer() {
    if (widget.videoPath == null ||
        widget.videoPath!.isEmpty ||
        _player != null) {
      return;
    }
    try {
      MediaKit.ensureInitialized();
      final player = Player();
      _player = player;
      _controller = VideoController(player);
      _positionSubscription = player.stream.position.listen((position) {
        final clipEnd = _clipEnd;
        if (clipEnd != null && position >= clipEnd) {
          unawaited(player.pause());
          if (mounted) {
            setState(() {
              _clipEnd = null;
              _clipPlaying = false;
            });
          }
        }
      });
    } catch (error) {
      _playerError = error.toString();
    }
  }

  Future<void> _loadVideo(String? path) async {
    final player = _player;
    if (path == null || path.isEmpty || player == null) return;
    try {
      await player.open(Media(Uri.file(path).toString()), play: false);
      await _seekToCandidate(widget.candidate);
      if (mounted) setState(() => _playerError = null);
    } catch (error) {
      if (mounted) setState(() => _playerError = error.toString());
    }
  }

  Future<void> _seekToCandidate(Map<String, dynamic>? candidate) async {
    final player = _player;
    final timeMs = _candidateTime(candidate);
    if (timeMs == null || player == null) return;
    await player.seek(Duration(milliseconds: timeMs));
  }

  Future<void> _togglePlayback(bool playing) async {
    final player = _player;
    if (player == null) return;
    if (playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> _playClip() async {
    final candidate = widget.candidate;
    if (candidate == null) return;
    final start = _clipStart(candidate);
    final end = _clipEndFor(candidate);
    final player = _player;
    if (player == null) return;
    await player.seek(Duration(milliseconds: start));
    setState(() {
      _clipEnd = Duration(milliseconds: end);
      _clipPlaying = true;
    });
    await player.play();
  }

  Future<void> _seek(Duration position) async {
    final player = _player;
    if (player != null) await player.seek(position);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final analyzing =
        widget.jobState == 'queued' || widget.jobState == 'running';
    final hasVideo = widget.videoPath != null && widget.videoPath!.isNotEmpty;
    final player = _player;
    final controller = _controller;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            if (widget.recoverable) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.pause_circle_outline,
                      color: scheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '上次分析没有完成，可以从头重试。已有候选和审核记录会保留。',
                        style: TextStyle(color: scheme.onTertiaryContainer),
                      ),
                    ),
                    if (widget.onRetry != null)
                      TextButton(
                        onPressed: widget.onRetry,
                        child: const Text('重试分析'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF080B0E),
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: hasVideo && controller != null && _playerError == null
                    ? ExcludeSemantics(child: Video(controller: controller))
                    : Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _playerError == null
                                  ? Icons.movie_outlined
                                  : Icons.error_outline,
                              size: 54,
                              color: _playerError == null
                                  ? scheme.primary
                                  : scheme.error,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              widget.videoPath == null
                                  ? '尚未导入视频'
                                  : analyzing
                                  ? '正在分析：${widget.jobState}'
                                  : '视频加载失败',
                            ),
                            if (_playerError != null) ...[
                              const SizedBox(height: 8),
                              SizedBox(
                                width: 420,
                                child: Text(
                                  _playerError!,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                            if (analyzing) ...[
                              const SizedBox(height: 14),
                              SizedBox(
                                width: 260,
                                child: LinearProgressIndicator(
                                  value: widget.progress,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text('${(widget.progress * 100).round()}%'),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: widget.onCancel,
                                icon: const Icon(Icons.stop_circle_outlined),
                                label: const Text('取消分析'),
                              ),
                            ],
                          ],
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            _PlayerControls(
              player: player,
              enabled: hasVideo && player != null && _playerError == null,
              hasPrevious: widget.hasPrevious,
              hasNext: widget.hasNext,
              onPrevious: widget.onPrevious,
              onNext: widget.onNext,
              onSeek: _seek,
              onTogglePlayback: _togglePlayback,
              onPlayClip: widget.candidate == null ? null : _playClip,
              clipPlaying: _clipPlaying,
            ),
            if (widget.candidate != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '候选 ${_formatMs(_candidateTime(widget.candidate) ?? 0)} · '
                  '片段 ${_formatMs(_clipStart(widget.candidate!))} - '
                  '${_formatMs(_clipEndFor(widget.candidate!))}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlayerControls extends StatelessWidget {
  const _PlayerControls({
    required this.player,
    required this.enabled,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onTogglePlayback,
    required this.onPlayClip,
    required this.clipPlaying,
  });
  final Player? player;
  final bool enabled;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function(bool) onTogglePlayback;
  final Future<void> Function()? onPlayClip;
  final bool clipPlaying;

  @override
  Widget build(BuildContext context) {
    final player = this.player;
    if (player == null) {
      return Row(
        children: [
          IconButton(
            tooltip: '上一候选',
            onPressed: null,
            icon: const Icon(Icons.skip_previous),
          ),
          IconButton(
            tooltip: '播放',
            onPressed: null,
            icon: const Icon(Icons.play_arrow),
          ),
          IconButton(
            tooltip: '下一候选',
            onPressed: null,
            icon: const Icon(Icons.skip_next),
          ),
          const SizedBox(width: 8),
          Text(_formatDuration(Duration.zero)),
          const Text(' / '),
          Text(_formatDuration(Duration.zero)),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: null,
            icon: const Icon(Icons.movie_filter_outlined),
            label: const Text('播放候选片段'),
          ),
        ],
      );
    }
    return StreamBuilder<Duration>(
      stream: player.stream.duration,
      initialData: Duration.zero,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final value = maxMs <= 0
                ? 0.0
                : position.inMilliseconds
                      .clamp(0, duration.inMilliseconds)
                      .toDouble();
            return Column(
              children: [
                Slider(
                  min: 0,
                  max: maxMs > 0 ? maxMs : 1,
                  value: value,
                  onChanged: !enabled || maxMs <= 0
                      ? null
                      : (value) =>
                            onSeek(Duration(milliseconds: value.round())),
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: '上一候选',
                      onPressed: enabled && hasPrevious ? onPrevious : null,
                      icon: const Icon(Icons.skip_previous),
                    ),
                    StreamBuilder<bool>(
                      stream: player.stream.playing,
                      initialData: false,
                      builder: (context, playingSnapshot) {
                        final playing = playingSnapshot.data ?? false;
                        return IconButton(
                          tooltip: playing ? '暂停' : '播放',
                          onPressed: enabled
                              ? () => onTogglePlayback(playing)
                              : null,
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: '下一候选',
                      onPressed: enabled && hasNext ? onNext : null,
                      icon: const Icon(Icons.skip_next),
                    ),
                    const SizedBox(width: 8),
                    Text(_formatDuration(position)),
                    const Text(' / '),
                    Text(_formatDuration(duration)),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: enabled && onPlayClip != null
                          ? onPlayClip
                          : null,
                      icon: Icon(
                        clipPlaying ? Icons.stop : Icons.movie_filter_outlined,
                      ),
                      label: Text(clipPlaying ? '播放中' : '播放候选片段'),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

int? _candidateTime(Map<String, dynamic>? candidate) {
  final value = candidate?['event_time_ms'];
  return value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
}

int _clipStart(Map<String, dynamic> candidate) {
  final value = candidate['review_start_ms'] ?? candidate['default_start_ms'];
  return value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? 0;
}

int _clipEndFor(Map<String, dynamic> candidate) {
  final value = candidate['review_end_ms'] ?? candidate['default_end_ms'];
  return value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ??
            ((_candidateTime(candidate) ?? 0) + 3000);
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

class _QueuePanel extends StatelessWidget {
  const _QueuePanel({
    required this.candidates,
    required this.selectedIndex,
    required this.busy,
    required this.onSelected,
    required this.onReview,
    required this.onUpdateRange,
    required this.onExport,
    required this.analyzing,
  });
  final List<Map<String, dynamic>> candidates;
  final int selectedIndex;
  final bool busy;
  final ValueChanged<int> onSelected;
  final Future<void> Function(String, String) onReview;
  final Future<void> Function(String, int, int) onUpdateRange;
  final VoidCallback onExport;
  final bool analyzing;

  @override
  Widget build(BuildContext context) {
    final pending = candidates
        .where((item) => item['review_status'] == 'pending')
        .length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('候选审核', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Chip(label: Text('$pending 待审核')),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: candidates.isEmpty
                  ? Center(
                      child: Text(
                        analyzing
                            ? '分析进行中，候选片段会自动出现在这里。\n你可以先等待进度完成。'
                            : '分析完成后，疑似进球会出现在这里。\n当前没有候选片段。',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: candidates.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = candidates[index];
                        final status =
                            item['review_status']?.toString() ?? 'pending';
                        final selected = index == selectedIndex;
                        final id = item['id']?.toString() ?? '';
                        final time =
                            (item['event_time_ms'] as num?)?.toInt() ?? 0;
                        return InkWell(
                          onTap: () => onSelected(index),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: selected
                                  ? Theme.of(context)
                                        .colorScheme
                                        .primaryContainer
                                        .withValues(alpha: .55)
                                  : Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withValues(alpha: .28),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      '#${index + 1}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(_formatMs(time)),
                                    const Spacer(),
                                    _StatusChip(status: status),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: busy
                                            ? null
                                            : () => onReview(id, 'goal'),
                                        icon: const Icon(Icons.check, size: 18),
                                        label: const Text('进球'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: busy
                                            ? null
                                            : () => onReview(id, 'excluded'),
                                        icon: const Icon(Icons.close, size: 18),
                                        label: const Text('排除'),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                TextButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () => _editRange(
                                          context,
                                          item,
                                          onUpdateRange,
                                        ),
                                  icon: const Icon(Icons.tune, size: 16),
                                  label: const Text('调整片段范围'),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    candidates.any((item) => item['review_status'] == 'goal')
                    ? onExport
                    : null,
                icon: const Icon(Icons.ios_share_outlined),
                label: const Text('去导出'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editRange(
    BuildContext context,
    Map<String, dynamic> item,
    Future<void> Function(String, int, int) save,
  ) async {
    final start = TextEditingController(
      text: '${item['review_start_ms'] ?? item['default_start_ms'] ?? 0}',
    );
    final end = TextEditingController(
      text: '${item['review_end_ms'] ?? item['default_end_ms'] ?? 0}',
    );
    final result = await showDialog<List<int>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('调整片段范围（毫秒）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: start,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '开始'),
            ),
            TextField(
              controller: end,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '结束'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final s = int.tryParse(start.text);
              final e = int.tryParse(end.text);
              if (s != null && e != null && e > s) {
                Navigator.pop(context, [s, e]);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null) await save(item['id'].toString(), result[0], result[1]);
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      'goal' => '已确认',
      'excluded' => '已排除',
      _ => '待审核',
    };
    return Chip(label: Text(label), visualDensity: VisualDensity.compact);
  }
}

String _formatMs(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final minutes = seconds ~/ 60;
  return '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}
