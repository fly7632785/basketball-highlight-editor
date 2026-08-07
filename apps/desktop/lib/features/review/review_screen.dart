import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../components/cs_button.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_progress_track.dart';
import '../../providers/project_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

/// 审核工作台：视频优先，候选默认保留，用户只需要打叉剔除误检。
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  String? _selectedCandidateId;
  final Map<String, Future<String?>> _coverCache = <String, Future<String?>>{};

  List<Map<String, dynamic>> _orderedCandidates(
    List<Map<String, dynamic>> candidates,
  ) {
    final ordered = [...candidates];
    ordered.sort(
      (left, right) => _candidateTime(left).compareTo(_candidateTime(right)),
    );
    return ordered;
  }

  Map<String, dynamic>? _selectedCandidate(
    List<Map<String, dynamic>> candidates,
  ) {
    if (candidates.isEmpty) return null;
    for (final candidate in candidates) {
      if (candidate['id']?.toString() == _selectedCandidateId) {
        return candidate;
      }
    }
    return candidates.first;
  }

  void _selectCandidate(Map<String, dynamic> candidate) {
    final id = candidate['id']?.toString();
    if (id != null && id.isNotEmpty) {
      setState(() => _selectedCandidateId = id);
    }
  }

  Future<void> _setCandidateStatus(
    String id,
    String status,
    List<Map<String, dynamic>> candidates,
  ) async {
    final index = candidates.indexWhere((candidate) => candidate['id'] == id);
    await ref
        .read(projectProvider.notifier)
        .reviewCandidate(id, status, showNotice: false);
    if (!mounted || status != 'excluded' || candidates.isEmpty) return;
    final nextIndex = (index + 1).clamp(0, candidates.length - 1).toInt();
    final nextId = candidates[nextIndex]['id']?.toString();
    if (nextId != null) setState(() => _selectedCandidateId = nextId);
  }

  Future<void> _confirmReanalyze() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重新分析当前视频？'),
        content: const Text('重新分析会替换当前候选列表，但不会删除原始视频。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重新分析'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(projectProvider.notifier).startAnalysis();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectProvider);
    final notifier = ref.read(projectProvider.notifier);
    final candidates = _orderedCandidates(state.candidates);
    final selected = _selectedCandidate(candidates);
    final job = state.job;
    final jobState = job?['state']?.toString() ?? '';
    final recoveryState = job?['recovery_state']?.toString();
    final analyzing =
        (jobState == 'queued' || jobState == 'running') &&
        (recoveryState == null || recoveryState == 'worker_attached');
    final progress = ((job?['progress'] as num?)?.toDouble() ?? 0)
        .clamp(0.0, 1.0)
        .toDouble();
    final playbackPath = _resolvePlaybackPath(state, analyzing: analyzing);
    final includedCount = candidates
        .where((candidate) => !_isExcluded(candidate))
        .length;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _moveCandidate(candidates, -1),
        SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _moveCandidate(candidates, 1),
        SingleActivator(LogicalKeyboardKey.keyX): () {
          final id = selected?['id']?.toString();
          if (id != null) {
            unawaited(_setCandidateStatus(id, 'excluded', candidates));
          }
        },
        SingleActivator(LogicalKeyboardKey.keyC): () {
          final id = selected?['id']?.toString();
          if (id != null) {
            unawaited(_setCandidateStatus(id, 'included', candidates));
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Padding(
          padding: const EdgeInsets.only(top: Spacing.xs, bottom: Spacing.sm),
          child: Column(
            children: [
              if (analyzing ||
                  jobState == 'failed' ||
                  jobState == 'cancelled' ||
                  (jobState == 'running' &&
                      recoveryState == 'stale_recoverable'))
                _AnalysisBar(
                  state: jobState,
                  stage: job?['stage']?.toString() ?? '',
                  progress: progress,
                  errorMessage: job?['error_message']?.toString(),
                  recoverable: job?['recoverable'] == true && !analyzing,
                  onCancel: analyzing ? () => notifier.cancelAnalysis() : null,
                  onRetry:
                      (jobState == 'failed' || job?['recoverable'] == true) &&
                          !state.busy
                      ? () => notifier.retryAnalysis()
                      : null,
                  onReanalyze: !analyzing && !state.busy
                      ? _confirmReanalyze
                      : null,
                )
              else if (jobState == 'completed')
                _CompletedLine(
                  candidateCount: candidates.length,
                  onReanalyze: state.busy ? null : _confirmReanalyze,
                ),
              const SizedBox(height: Spacing.sm),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final video = _VideoPane(
                      key: ValueKey(playbackPath ?? 'no-video'),
                      videoPath: playbackPath,
                      candidate: selected,
                      frameSize: _videoFrameSize(state.video),
                      hasPrevious: _candidateIndex(candidates, selected) > 0,
                      hasNext:
                          _candidateIndex(candidates, selected) <
                          candidates.length - 1,
                      onPrevious: () => _moveCandidate(candidates, -1),
                      onNext: () => _moveCandidate(candidates, 1),
                    );
                    final queueWidth = (constraints.maxWidth * 0.28)
                        .clamp(296.0, 360.0)
                        .toDouble();
                    final queue = _CandidatePanel(
                      candidates: candidates,
                      selectedId: selected?['id']?.toString(),
                      includedCount: includedCount,
                      busy: state.busy,
                      analyzing: analyzing,
                      hasVideo: state.videoPath != null,
                      onSelect: _selectCandidate,
                      onSetStatus: (id, status) =>
                          _setCandidateStatus(id, status, candidates),
                      onLoadCover: state.video == null
                          ? null
                          : (id, timeMs) =>
                                _loadCandidateCover(notifier, id, timeMs),
                      onReanalyze: !analyzing && !state.busy
                          ? _confirmReanalyze
                          : null,
                      onGoImport: () => context.go('/import'),
                      onExport: includedCount == 0
                          ? null
                          : () => context.go('/export'),
                    );
                    if (constraints.maxWidth >= Breakpoints.md) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: video),
                          const SizedBox(width: Spacing.sm),
                          SizedBox(width: queueWidth, child: queue),
                        ],
                      );
                    }
                    return SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: Spacing.lg),
                      child: Column(
                        children: [
                          SizedBox(
                            height: (constraints.maxWidth * 0.62)
                                .clamp(300.0, 520.0)
                                .toDouble(),
                            child: video,
                          ),
                          const SizedBox(height: Spacing.md),
                          SizedBox(height: 520, child: queue),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int _candidateIndex(
    List<Map<String, dynamic>> candidates,
    Map<String, dynamic>? selected,
  ) {
    if (selected == null) return 0;
    final index = candidates.indexWhere(
      (candidate) => candidate['id'] == selected['id'],
    );
    return index < 0 ? 0 : index;
  }

  void _moveCandidate(List<Map<String, dynamic>> candidates, int delta) {
    if (candidates.isEmpty) return;
    final selected = _selectedCandidate(candidates);
    final current = _candidateIndex(candidates, selected);
    final next = (current + delta).clamp(0, candidates.length - 1).toInt();
    _selectCandidate(candidates[next]);
  }

  Future<String?> _loadCandidateCover(
    ProjectNotifier notifier,
    String candidateId,
    int timeMs,
  ) {
    final key = '$candidateId:$timeMs';
    return _coverCache.putIfAbsent(
      key,
      () => notifier.loadCandidatePreview(timeMs),
    );
  }
}

class _AnalysisBar extends StatelessWidget {
  const _AnalysisBar({
    required this.state,
    required this.stage,
    required this.progress,
    required this.errorMessage,
    required this.recoverable,
    required this.onCancel,
    required this.onRetry,
    required this.onReanalyze,
  });

  final String state;
  final String stage;
  final double progress;
  final String? errorMessage;
  final bool recoverable;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;
  final VoidCallback? onReanalyze;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final failed = state == 'failed';
    final interrupted = recoverable || state == 'cancelled';
    final active = !failed && !interrupted;
    final value = progress.clamp(0.0, 1.0).toDouble();
    final color = failed
        ? c.error
        : interrupted
        ? c.warning
        : c.indigo;
    final title = failed
        ? '分析失败'
        : interrupted
        ? '上次分析没有完成'
        : '正在分析视频';
    final detail = failed
        ? (errorMessage ?? '请检查视频后重试')
        : interrupted
        ? '已有候选可以继续使用，也可以重新分析'
        : '${_stageLabel(stage)} · ${(value * 100).round()}%';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(CsRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(
            failed ? Icons.error_outline : Icons.auto_awesome,
            size: 17,
            color: color,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                if (active) ...[
                  const SizedBox(height: Spacing.xs),
                  const Text('分析进行中', style: TextStyle(fontSize: 10)),
                  const SizedBox(height: Spacing.xs),
                  CsProgressTrack(value: value),
                ],
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          if (onCancel != null)
            _SmallAction(
              label: '取消',
              icon: Icons.stop_circle_outlined,
              onPressed: onCancel!,
            ),
          if (onRetry != null)
            _SmallAction(
              label: '重试分析',
              icon: Icons.refresh,
              onPressed: onRetry!,
            ),
          if (onReanalyze != null)
            _SmallAction(
              label: '重新分析',
              icon: Icons.replay,
              onPressed: onReanalyze!,
            ),
        ],
      ),
    );
  }
}

class _CompletedLine extends StatelessWidget {
  const _CompletedLine({
    required this.candidateCount,
    required this.onReanalyze,
  });

  final int candidateCount;
  final VoidCallback? onReanalyze;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 16, color: c.goal),
          const SizedBox(width: Spacing.xs),
          Text(
            '分析完成 · $candidateCount 个候选',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
          ),
          const Spacer(),
          if (onReanalyze != null)
            TextButton.icon(
              onPressed: onReanalyze,
              icon: const Icon(Icons.replay, size: 15),
              label: const Text('重新分析'),
            ),
        ],
      ),
    );
  }
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 15),
    label: Text(label),
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
  );
}

class _VideoPane extends StatefulWidget {
  const _VideoPane({
    super.key,
    required this.videoPath,
    required this.candidate,
    required this.frameSize,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
  });

  final String? videoPath;
  final Map<String, dynamic>? candidate;
  final Size frameSize;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  State<_VideoPane> createState() => _VideoPaneState();
}

class _VideoPaneState extends State<_VideoPane> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _positionSubscription;
  String? _error;
  bool _ready = false;
  bool _loading = false;
  bool _showAnnotations = true;
  int _positionMs = 0;
  int? _clipEndMs;
  int _playRequest = 0;

  @override
  void initState() {
    super.initState();
    if (widget.videoPath == null || widget.videoPath!.isEmpty) return;
    try {
      MediaKit.ensureInitialized();
      _player = Player();
      _controller = VideoController(_player!);
    } catch (error) {
      _error = error.toString();
      return;
    }
    _positionSubscription = _player!.stream.position.listen((position) {
      final end = _clipEndMs;
      if (end != null && position.inMilliseconds >= end) {
        unawaited(_player!.pause());
        if (mounted) setState(() => _clipEndMs = null);
      }
      if (mounted) {
        setState(() => _positionMs = position.inMilliseconds);
      }
    });
    unawaited(_open(widget.videoPath));
  }

  @override
  void didUpdateWidget(covariant _VideoPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _ready = false;
      unawaited(_open(widget.videoPath));
    } else if (_candidateSignature(oldWidget.candidate) !=
        _candidateSignature(widget.candidate)) {
      unawaited(_playCandidate());
    }
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _open(String? path) async {
    final player = _player;
    if (player == null || path == null || path.isEmpty) return;
    if (mounted) setState(() => _loading = true);
    try {
      await player.open(Media(Uri.file(path).toString()), play: false);
      if (!mounted) return;
      setState(() {
        _ready = true;
        _loading = false;
        _error = null;
      });
      await _playCandidate();
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _ready = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _playCandidate() async {
    final player = _player;
    final candidate = widget.candidate;
    if (player == null || !_ready || candidate == null) return;
    final start = _clipStart(candidate);
    final end = _clipEnd(candidate);
    final request = ++_playRequest;
    try {
      await player.seek(Duration(milliseconds: start));
      if (!mounted || request != _playRequest) return;
      setState(() => _clipEndMs = end);
      await player.play();
    } catch (error) {
      if (mounted && request == _playRequest) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _seek(Duration position) async {
    if (_player != null && _ready) {
      await _player!.seek(position);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final player = _player;
    final controller = _controller;
    final hasVideo = widget.videoPath != null && widget.videoPath!.isNotEmpty;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(CsRadius.md),
      ),
      child: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(color: Colors.black),
              clipBehavior: Clip.hardEdge,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (!hasVideo || controller == null || _error != null)
                    CsEmptyState(
                      icon: _error == null
                          ? Icons.movie_outlined
                          : Icons.error_outline,
                      title: !hasVideo ? '还没有视频' : _error ?? '视频加载失败',
                      description: _error == null && hasVideo
                          ? '分析完成后会在这里播放候选片段'
                          : null,
                      action: null,
                    )
                  else
                    Center(
                      child: AspectRatio(
                        aspectRatio: _videoAspectRatio(widget.frameSize),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Video(
                              controller: controller,
                              controls: NoVideoControls,
                            ),
                            if (_showAnnotations && widget.candidate != null)
                              _CandidateAnnotationLayer(
                                candidate: widget.candidate!,
                                frameSize: widget.frameSize,
                                positionMs: _positionMs,
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (_loading)
                    const ColoredBox(
                      color: Colors.black26,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (widget.candidate != null)
                    Positioned(
                      top: Spacing.sm,
                      right: Spacing.sm,
                      child: _AnnotationToggle(
                        enabled: _showAnnotations,
                        onChanged: (value) =>
                            setState(() => _showAnnotations = value),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          _VideoControls(
            player: player,
            positionMs: _positionMs,
            enabled: _ready && _error == null,
            hasPrevious: widget.hasPrevious,
            hasNext: widget.hasNext,
            onPrevious: widget.onPrevious,
            onNext: widget.onNext,
            onSeek: _seek,
            onReplayCandidate: _playCandidate,
          ),
          if (widget.candidate != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.sm,
                  0,
                  Spacing.sm,
                  Spacing.xs,
                ),
                child: Text(
                  '候选 ${_formatMs(_candidateTime(widget.candidate!))}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            _CandidateEvidencePanel(candidate: widget.candidate!),
          ],
        ],
      ),
    );
  }
}

class _AnnotationToggle extends StatelessWidget {
  const _AnnotationToggle({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: c.background.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(CsRadius.md),
      child: Padding(
        padding: const EdgeInsets.only(left: Spacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('标注', style: TextStyle(color: c.textPrimary, fontSize: 11)),
            Tooltip(
              message: enabled ? '关闭标注' : '显示标注',
              child: Switch(
                value: enabled,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateAnnotationLayer extends StatelessWidget {
  const _CandidateAnnotationLayer({
    required this.candidate,
    required this.frameSize,
    required this.positionMs,
  });

  final Map<String, dynamic> candidate;
  final Size frameSize;
  final int positionMs;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _CandidateAnnotationPainter(
        candidate: candidate,
        frameSize: frameSize,
        positionMs: positionMs,
      ),
      child: const SizedBox.expand(),
    ),
  );
}

class _CandidateAnnotationPainter extends CustomPainter {
  _CandidateAnnotationPainter({
    required this.candidate,
    required this.frameSize,
    required this.positionMs,
  });

  final Map<String, dynamic> candidate;
  final Size frameSize;
  final int positionMs;

  @override
  void paint(Canvas canvas, Size size) {
    if (frameSize.width <= 0 || frameSize.height <= 0) return;
    final evidence = _candidateEvidence(candidate);
    final rawOverlay = evidence['overlay'];
    if (rawOverlay is! Map) return;
    final overlay = rawOverlay.cast<String, dynamic>();
    final rim = overlay['rim'];
    if (rim is! Map) return;

    final current = positionMs / 1000.0;
    final centerX = _pointX(rim['center_x'], size.width);
    final rimY = _pointY(rim['rim_y'], size.height);
    final rimWidth = _scaledX(rim['width'], size.width);
    final rimHeight = _scaledY(rim['height'] ?? 12, size.height);
    final rimPaint = Paint()
      ..color = const Color(0xFFFFB454)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(centerX, rimY),
        width: rimWidth,
        height: rimHeight.clamp(4.0, 28.0).toDouble(),
      ),
      rimPaint,
    );
    canvas.drawLine(
      Offset(centerX - rimWidth / 2, rimY),
      Offset(centerX + rimWidth / 2, rimY),
      rimPaint,
    );

    final rawTrajectory = overlay['trajectory'];
    final points = rawTrajectory is List
        ? rawTrajectory
              .whereType<Map>()
              .map((point) => point.cast<String, dynamic>())
              .where((point) => _number(point['time']) <= current + 0.02)
              .map(
                (point) => Offset(
                  _pointX(point['x'], size.width),
                  _pointY(point['y'], size.height),
                ),
              )
              .toList()
        : <Offset>[];
    if (points.length >= 2) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF9AA6FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }

    final crossing = overlay['crossing'];
    final crossingTime = crossing is Map ? _number(crossing['time']) : -1;
    final crossingX = crossing is Map
        ? _pointX(crossing['x'], size.width)
        : 0.0;
    final crossingY = crossing is Map
        ? _pointY(crossing['y'], size.height)
        : 0.0;
    final valid = crossing is Map && crossing['valid'] == true;
    final resultColor = valid
        ? const Color(0xFF65C982)
        : const Color(0xFFF17D76);

    if (points.isNotEmpty && crossingTime > current) {
      final prediction = overlay['prediction'];
      if (prediction is Map && prediction['landing_x'] != null) {
        _drawDashedLine(
          canvas,
          points.last,
          Offset(_pointX(prediction['landing_x'], size.width), rimY),
          Paint()
            ..color = const Color(0xFF9AA6FF)
            ..strokeWidth = 2,
        );
      }
    }

    if (points.isNotEmpty) {
      final ballPaint = Paint()..color = const Color(0xFFE97832);
      canvas.drawCircle(points.last, 7, ballPaint);
      canvas.drawCircle(
        points.last,
        11,
        Paint()
          ..color = const Color(0xFFE97832).withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    if (crossingTime >= 0 && current >= crossingTime - 0.2) {
      final pulse = (1 - ((current - crossingTime).abs() / 0.45))
          .clamp(0.0, 1.0)
          .toDouble();
      canvas.drawCircle(
        Offset(crossingX, crossingY),
        10 + 14 * pulse,
        Paint()
          ..color = resultColor.withValues(alpha: 0.70 * pulse)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      canvas.drawCircle(
        Offset(crossingX, crossingY),
        5,
        Paint()..color = resultColor,
      );
    }
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const segments = 10;
    for (var index = 0; index < segments; index += 2) {
      final startT = index / segments;
      final endT = (index + 1) / segments;
      canvas.drawLine(
        Offset.lerp(start, end, startT)!,
        Offset.lerp(start, end, endT)!,
        paint,
      );
    }
  }

  double _pointX(dynamic value, double width) =>
      (_number(value) / frameSize.width).clamp(0.0, 1.0) * width;

  double _pointY(dynamic value, double height) =>
      (_number(value) / frameSize.height).clamp(0.0, 1.0) * height;

  double _scaledX(dynamic value, double width) =>
      (_number(value) / frameSize.width).clamp(0.0, 1.0) * width;

  double _scaledY(dynamic value, double height) =>
      (_number(value) / frameSize.height).clamp(0.0, 1.0) * height;

  @override
  bool shouldRepaint(covariant _CandidateAnnotationPainter oldDelegate) =>
      oldDelegate.positionMs != positionMs ||
      oldDelegate.candidate != candidate;
}

class _VideoControls extends StatelessWidget {
  const _VideoControls({
    required this.player,
    required this.positionMs,
    required this.enabled,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onReplayCandidate,
  });

  final Player? player;
  final int positionMs;
  final bool enabled;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function() onReplayCandidate;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    if (player == null) return const SizedBox(height: 32);
    return StreamBuilder<Duration>(
      stream: player!.stream.duration,
      initialData: player!.state.duration,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final max = duration.inMilliseconds;
        final value = max <= 0 ? 0.0 : positionMs.clamp(0, max).toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
          child: Column(
            children: [
              SizedBox(
                height: 22,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 4,
                    ),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    min: 0,
                    max: max > 0 ? max.toDouble() : 1,
                    value: value,
                    onChanged: !enabled || max <= 0
                        ? null
                        : (next) =>
                              onSeek(Duration(milliseconds: next.round())),
                  ),
                ),
              ),
              Row(
                children: [
                  Text(
                    '${_formatDuration(Duration(milliseconds: positionMs))} / '
                    '${_formatDuration(duration)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '上一个候选',
                    onPressed: enabled && hasPrevious ? onPrevious : null,
                    icon: const Icon(Icons.skip_previous, size: 19),
                    constraints: const BoxConstraints.tightFor(
                      width: 34,
                      height: 34,
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  StreamBuilder<bool>(
                    stream: player!.stream.playing,
                    initialData: false,
                    builder: (context, snapshot) => IconButton(
                      tooltip: snapshot.data == true ? '暂停' : '播放',
                      onPressed: !enabled
                          ? null
                          : () => snapshot.data == true
                                ? player!.pause()
                                : player!.play(),
                      icon: Icon(
                        snapshot.data == true ? Icons.pause : Icons.play_arrow,
                        size: 22,
                      ),
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  IconButton(
                    tooltip: '下一个候选',
                    onPressed: enabled && hasNext ? onNext : null,
                    icon: const Icon(Icons.skip_next, size: 19),
                    constraints: const BoxConstraints.tightFor(
                      width: 34,
                      height: 34,
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: '重播当前片段',
                    onPressed: enabled
                        ? () => unawaited(onReplayCandidate())
                        : null,
                    icon: const Icon(Icons.replay, size: 18),
                    constraints: const BoxConstraints.tightFor(
                      width: 34,
                      height: 34,
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CandidateEvidencePanel extends StatelessWidget {
  const _CandidateEvidencePanel({required this.candidate});

  final Map<String, dynamic> candidate;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final evidence = _candidateEvidence(candidate);
    final trajectory = _candidateEvidenceValue(candidate, evidence, const [
      ['verification', 'trajectory_cross'],
      ['trajectory_cross'],
    ]);
    final net = _candidateEvidenceValue(candidate, evidence, const [
      ['signals', 'net_score'],
      ['net_score'],
      ['net_motion_score'],
    ]);
    final audio = _candidateEvidenceValue(candidate, evidence, const [
      ['signals', 'audio_score'],
      ['audio_score'],
      ['audio_support'],
    ]);
    final rebound = _candidateEvidenceValue(candidate, evidence, const [
      ['verification', 'rebound'],
      ['rim_rebound'],
      ['rebound'],
    ]);
    final reason = _candidateEvidenceValue(candidate, evidence, const [
      ['review_reason_suggestion', 'primary'],
      ['review_reason'],
    ]);
    final clip =
        '片段 ${_formatMs(_clipStart(candidate))} - ${_formatMs(_clipEnd(candidate))} · '
        '时长 ${_formatClipDuration(_clipEnd(candidate) - _clipStart(candidate))}';

    return Container(
      width: double.infinity,
      height: 58,
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: 5,
        ),
        child: Row(
          children: [
            _EvidenceCell(
              label: '片段',
              value: clip,
              width: 190,
              color: c.textPrimary,
            ),
            _EvidenceCell(
              label: '置信度',
              value: _candidateConfidence(candidate) ?? '—',
              width: 72,
              color: c.textPrimary,
            ),
            _EvidenceCell(
              label: '轨迹穿框',
              value: _formatCrossing(trajectory),
              width: 82,
              color: _boolColor(c, trajectory),
            ),
            _EvidenceCell(
              label: '篮网运动',
              value: _formatSignal(net),
              width: 82,
              color: _signalColor(c, net),
            ),
            _EvidenceCell(
              label: '音频支持',
              value: _formatSignal(audio),
              width: 82,
              color: _signalColor(c, audio),
            ),
            _EvidenceCell(
              label: '反弹判断',
              value: _formatRebound(rebound),
              width: 82,
              color: _reboundColor(c, rebound),
            ),
            _EvidenceCell(
              label: '系统说明',
              value: _reviewReasonLabel(reason),
              width: 135,
              color: c.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _EvidenceCell extends StatelessWidget {
  const _EvidenceCell({
    required this.label,
    required this.value,
    required this.width,
    required this.color,
  });

  final String label;
  final String value;
  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: c.textTertiary, fontSize: 9)),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidatePanel extends StatelessWidget {
  const _CandidatePanel({
    required this.candidates,
    required this.selectedId,
    required this.includedCount,
    required this.busy,
    required this.analyzing,
    required this.hasVideo,
    required this.onSelect,
    required this.onSetStatus,
    required this.onLoadCover,
    required this.onReanalyze,
    required this.onGoImport,
    required this.onExport,
  });

  final List<Map<String, dynamic>> candidates;
  final String? selectedId;
  final int includedCount;
  final bool busy;
  final bool analyzing;
  final bool hasVideo;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final Future<void> Function(String, String) onSetStatus;
  final Future<String?> Function(String, int)? onLoadCover;
  final VoidCallback? onReanalyze;
  final VoidCallback onGoImport;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(CsRadius.md),
      ),
      padding: const EdgeInsets.fromLTRB(
        Spacing.sm,
        Spacing.xs,
        Spacing.sm,
        Spacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('候选片段', style: theme.textTheme.titleSmall),
              const SizedBox(width: Spacing.sm),
              Text(
                '已选 $includedCount / ${candidates.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: c.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Expanded(
            child: candidates.isEmpty
                ? _EmptyCandidates(
                    analyzing: analyzing,
                    hasVideo: hasVideo,
                    onReanalyze: onReanalyze,
                    onGoImport: onGoImport,
                  )
                : ListView.separated(
                    itemCount: candidates.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      color: c.border.withValues(alpha: 0.7),
                    ),
                    itemBuilder: (context, index) {
                      final candidate = candidates[index];
                      final id = candidate['id']?.toString() ?? '';
                      return _CandidateRow(
                        candidate: candidate,
                        index: index,
                        selected: id == selectedId,
                        excluded: _isExcluded(candidate),
                        busy: busy,
                        onTap: () => onSelect(candidate),
                        onInclude: () => unawaited(onSetStatus(id, 'included')),
                        onExclude: () => unawaited(onSetStatus(id, 'excluded')),
                        onLoadCover: onLoadCover == null
                            ? null
                            : () => onLoadCover!(id, _candidateTime(candidate)),
                      );
                    },
                  ),
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              Expanded(
                child: CsButton(
                  label: Text('导出 $includedCount 个片段'),
                  icon: Icons.file_upload_outlined,
                  size: CsButtonSize.sm,
                  onPressed: onExport,
                ),
              ),
              if (onReanalyze != null) ...[
                const SizedBox(width: Spacing.xs),
                IconButton(
                  tooltip: '重新分析当前视频',
                  onPressed: onReanalyze,
                  icon: const Icon(Icons.replay, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyCandidates extends StatelessWidget {
  const _EmptyCandidates({
    required this.analyzing,
    required this.hasVideo,
    required this.onReanalyze,
    required this.onGoImport,
  });

  final bool analyzing;
  final bool hasVideo;
  final VoidCallback? onReanalyze;
  final VoidCallback onGoImport;

  @override
  Widget build(BuildContext context) {
    if (analyzing) {
      return const CsEmptyState(
        icon: Icons.hourglass_top,
        title: '正在等待候选片段',
        description: '候选会在分析过程中自动出现。',
      );
    }
    return CsEmptyState(
      icon: Icons.inbox_outlined,
      title: hasVideo ? '暂未找到候选片段' : '还没有分析结果',
      description: hasVideo ? '可以重新分析当前视频，或先调整篮筐区域。' : '先导入视频并框选篮筐区域，再开始分析。',
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: Spacing.xs,
        children: [
          if (hasVideo)
            CsButton(
              label: const Text('重新分析'),
              icon: Icons.replay,
              onPressed: onReanalyze,
            ),
          CsButton(
            label: Text(hasVideo ? '调整区域' : '去导入视频'),
            icon: hasVideo ? Icons.crop : Icons.upload_file,
            variant: CsButtonVariant.secondary,
            onPressed: onGoImport,
          ),
        ],
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.candidate,
    required this.index,
    required this.selected,
    required this.excluded,
    required this.busy,
    required this.onTap,
    required this.onInclude,
    required this.onExclude,
    required this.onLoadCover,
  });

  final Map<String, dynamic> candidate;
  final int index;
  final bool selected;
  final bool excluded;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onInclude;
  final VoidCallback onExclude;
  final Future<String?> Function()? onLoadCover;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(CsRadius.sm),
          child: AnimatedContainer(
            duration: DurationD.fast,
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.xs,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: selected ? c.indigo.withValues(alpha: 0.10) : null,
              borderRadius: BorderRadius.circular(CsRadius.sm),
              border: selected
                  ? Border.all(color: c.indigo.withValues(alpha: 0.45))
                  : null,
            ),
            child: Row(
              children: [
                _CandidateCover(load: onLoadCover, excluded: excluded),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    '${index + 1}. ${_formatMs(_candidateTime(candidate))}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: excluded ? c.textTertiary : c.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                SizedBox(
                  width: 112,
                  child: Row(
                    children: [
                      Expanded(
                        child: IconButton(
                          tooltip: '保留片段',
                          onPressed: busy ? null : onInclude,
                          icon: Icon(
                            Icons.check_circle,
                            size: 25,
                            color: excluded ? c.textTertiary : c.goal,
                          ),
                          constraints: const BoxConstraints.tightFor(
                            width: 52,
                            height: 44,
                          ),
                          padding: EdgeInsets.zero,
                          style: IconButton.styleFrom(
                            backgroundColor: excluded
                                ? c.surface3
                                : c.goal.withValues(alpha: 0.12),
                            foregroundColor: excluded ? c.textTertiary : c.goal,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(CsRadius.sm),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.xs),
                      Expanded(
                        child: IconButton(
                          tooltip: '排除片段',
                          onPressed: busy ? null : onExclude,
                          icon: Icon(
                            Icons.cancel_outlined,
                            size: 25,
                            color: excluded ? c.error : c.textTertiary,
                          ),
                          constraints: const BoxConstraints.tightFor(
                            width: 52,
                            height: 44,
                          ),
                          padding: EdgeInsets.zero,
                          style: IconButton.styleFrom(
                            backgroundColor: excluded
                                ? c.error.withValues(alpha: 0.12)
                                : c.surface3,
                            foregroundColor: excluded
                                ? c.error
                                : c.textTertiary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(CsRadius.sm),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CandidateCover extends StatefulWidget {
  const _CandidateCover({required this.load, required this.excluded});

  final Future<String?> Function()? load;
  final bool excluded;

  @override
  State<_CandidateCover> createState() => _CandidateCoverState();
}

class _CandidateCoverState extends State<_CandidateCover> {
  late Future<String?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load == null ? Future.value(null) : widget.load!();
  }

  @override
  void didUpdateWidget(covariant _CandidateCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.load != widget.load) {
      _future = widget.load == null ? Future.value(null) : widget.load!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return FutureBuilder<String?>(
      future: _future,
      builder: (context, snapshot) {
        final path = snapshot.data;
        final cover = path != null && File(path).existsSync()
            ? Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(c),
              )
            : _placeholder(c);
        return Opacity(
          opacity: widget.excluded ? 0.45 : 1,
          child: SizedBox(
            width: 82,
            height: 52,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(CsRadius.sm),
              child: cover,
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder(AppColors c) => ColoredBox(
    color: c.surface3,
    child: Icon(Icons.movie_outlined, size: 19, color: c.textTertiary),
  );
}

bool _isExcluded(Map<String, dynamic> candidate) =>
    candidate['selection_status']?.toString() == 'excluded' ||
    candidate['review_status']?.toString() == 'excluded';

int _candidateTime(Map<String, dynamic> candidate) {
  final value = candidate['event_time_ms'];
  return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

int _clipStart(Map<String, dynamic> candidate) {
  final value = candidate['review_start_ms'] ?? candidate['default_start_ms'];
  return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

int _clipEnd(Map<String, dynamic> candidate) {
  final value = candidate['review_end_ms'] ?? candidate['default_end_ms'];
  return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

String _candidateSignature(Map<String, dynamic>? candidate) {
  if (candidate == null) return '';
  return '${candidate['id']}|${_clipStart(candidate)}|${_clipEnd(candidate)}';
}

Map<String, dynamic> _candidateEvidence(Map<String, dynamic> candidate) {
  final raw = candidate['evidence_json'] ?? candidate['evidence'];
  if (raw is Map) return raw.cast<String, dynamic>();
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on FormatException {
      return const <String, dynamic>{};
    }
  }
  return const <String, dynamic>{};
}

double _number(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0.0;
}

Size _videoFrameSize(Map<String, dynamic>? video) {
  final width = _number(video?['width']);
  final height = _number(video?['height']);
  if (width <= 0 || height <= 0) return const Size(16, 9);
  return Size(width, height);
}

double _videoAspectRatio(Size frameSize) =>
    frameSize.width > 0 && frameSize.height > 0
    ? frameSize.width / frameSize.height
    : 16 / 9;

dynamic _candidateEvidenceValue(
  Map<String, dynamic> candidate,
  Map<String, dynamic> evidence,
  List<List<String>> paths,
) {
  for (final path in paths) {
    final fromEvidence = _readEvidencePath(evidence, path);
    if (fromEvidence != null) return fromEvidence;
    final fromCandidate = _readEvidencePath(candidate, path);
    if (fromCandidate != null) return fromCandidate;
  }
  return null;
}

dynamic _readEvidencePath(Map<String, dynamic> source, List<String> path) {
  dynamic current = source;
  for (final key in path) {
    if (current is! Map || !current.containsKey(key)) return null;
    current = current[key];
  }
  return current;
}

String _formatCrossing(dynamic value) {
  if (value is bool) return value ? '通过' : '未通过';
  return '—';
}

String _formatSignal(dynamic value) {
  if (value is bool) return value ? '有支持' : '不足';
  if (value is num) {
    if (value >= 0.65) return '明显';
    if (value >= 0.15) return '有运动';
    return '不足';
  }
  return '—';
}

String _formatRebound(dynamic value) {
  if (value is bool) return value ? '检测到' : '未发现';
  return '—';
}

String _reviewReasonLabel(dynamic value) =>
    const <String, String>{
      'pass_ball': '可能传球',
      'no_shot': '可能未形成投篮',
      'rim_out': '可能擦框/弹出',
      'rebound': '可能反弹',
      'net_no_motion': '篮网运动不足',
      'uncertain': '证据不确定',
    }[value?.toString()] ??
    '—';

Color _boolColor(AppColors c, dynamic value) => value is bool
    ? value
          ? c.success
          : c.warning
    : c.textSecondary;

Color _signalColor(AppColors c, dynamic value) =>
    value is num && value >= 0.65 ? c.success : c.textSecondary;

Color _reboundColor(AppColors c, dynamic value) =>
    value is bool && value ? c.warning : c.textSecondary;

String? _candidateConfidence(Map<String, dynamic> candidate) {
  final raw = candidate['confidence']?.toString();
  if (raw != null && raw.isNotEmpty) {
    return const <String, String>{
          'high': '高',
          'review': '复核',
          'medium': '中',
          'low': '低',
        }[raw] ??
        raw;
  }
  final score = candidate['score'];
  if (score is num) return '${(score.clamp(0, 1) * 100).round()}%';
  return null;
}

String _formatClipDuration(int milliseconds) {
  final seconds = (milliseconds / 1000).round();
  if (seconds < 60) return '$seconds 秒';
  return '${seconds ~/ 60} 分 ${seconds % 60} 秒';
}

String _formatMs(int milliseconds) {
  final totalSeconds = milliseconds.clamp(0, 359999999).toInt() ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${(totalSeconds % 60).toString().padLeft(2, '0')}';
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

String? _resolvePlaybackPath(ProjectState state, {required bool analyzing}) {
  final paths = analyzing
      ? <String?>[state.reviewVideoPath, state.videoPath]
      : <String?>[state.videoPath, state.reviewVideoPath];
  for (final path in paths) {
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return path;
    }
  }
  for (final path in paths) {
    if (path != null && path.isNotEmpty) return path;
  }
  return null;
}

String _stageLabel(String stage) =>
    const <String, String>{
      'validate_input': '检查视频输入',
      'prepare_proxy': '生成预览视频',
      'coarse_scan': '快速扫描候选',
      'generate_candidates': '生成候选',
      'refine_candidates': '精细分析候选',
      'persist_candidates': '整理审核片段',
    }[stage] ??
    stage;
