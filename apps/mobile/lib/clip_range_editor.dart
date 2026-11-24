import 'dart:async';

import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';

import 'features/diagnostics/mobile_diagnostics.dart';
import 'mobile_theme.dart';
import 'features/video_source/video_unavailable.dart';
import 'features/video_source/video_playback.dart';

enum ClipRangeHandle { start, end }

/// Opens the clip range editor and returns the chosen range, or null when
/// the sheet is dismissed.
Future<({int start, int end})?> showClipRangeEditor(
  BuildContext context, {
  required String videoPath,
  required double aspectRatio,
  required int durationMs,
  required int startMs,
  required int endMs,
  required String title,
  required String confirmLabel,
  IconData confirmIcon = LucideIcons.check,
  String? description,
  int? eventMs,
  int? defaultStartMs,
  int? defaultEndMs,
  ValueChanged<DiagnosticErrorRecord>? onFeedback,
}) => showModalBottomSheet<({int start, int end})>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => ClipRangeEditor(
    videoPath: videoPath,
    aspectRatio: aspectRatio,
    durationMs: durationMs,
    startMs: startMs,
    endMs: endMs,
    title: title,
    confirmLabel: confirmLabel,
    confirmIcon: confirmIcon,
    description: description,
    eventMs: eventMs,
    defaultStartMs: defaultStartMs,
    defaultEndMs: defaultEndMs,
    onFeedback: onFeedback,
  ),
);

/// Mobile counterpart of the desktop clip range dialog: a zoomed timeline
/// around the clip, playback that loops inside the range, and controls to
/// set or nudge either end.
class ClipRangeEditor extends StatefulWidget {
  const ClipRangeEditor({
    super.key,
    required this.videoPath,
    required this.aspectRatio,
    required this.durationMs,
    required this.startMs,
    required this.endMs,
    required this.title,
    required this.confirmLabel,
    this.confirmIcon = LucideIcons.check,
    this.description,
    this.eventMs,
    this.defaultStartMs,
    this.defaultEndMs,
    this.onFeedback,
  });

  final String videoPath;
  final double aspectRatio;
  final int durationMs;
  final int startMs;
  final int endMs;
  final String title;
  final String confirmLabel;
  final IconData confirmIcon;
  final String? description;
  final int? eventMs;
  final int? defaultStartMs;
  final int? defaultEndMs;
  final ValueChanged<DiagnosticErrorRecord>? onFeedback;

  @override
  State<ClipRangeEditor> createState() => _ClipRangeEditorState();
}

class _ClipRangeEditorState extends State<ClipRangeEditor> {
  static const int _windowPaddingMs = 15000;
  static const int _windowStepMs = 5000;
  static const int _minClipMs = 1000;

  VideoPlayerController? _player;
  late int _startMs;
  late int _endMs;
  late int _windowStartMs;
  late int _windowEndMs;
  int _positionMs = 0;
  bool _ready = false;
  bool _failed = false;
  DiagnosticErrorRecord? _diagnosticFailure;
  // Playback started inside the range stays inside it: it loops, or stops
  // at the end for an ending preview. Playback started outside the range
  // browses freely so an earlier or later moment can be found.
  bool _boundedPlayback = false;
  bool _loopRange = true;
  bool _wrapping = false;
  Timer? _scrubTimer;
  int? _pendingScrubMs;

  @override
  void initState() {
    super.initState();
    _startMs = widget.startMs;
    _endMs = widget.endMs;
    _windowStartMs = (_startMs - _windowPaddingMs)
        .clamp(0, widget.durationMs - _minClipMs)
        .toInt();
    _windowEndMs = (_endMs + _windowPaddingMs)
        .clamp(_windowStartMs + _minClipMs, widget.durationMs)
        .toInt();
    _positionMs = _startMs;
    unawaited(_openVideo());
  }

  Future<void> _openVideo() async {
    final player = sourceVideoController(widget.videoPath);
    _player = player;
    player.addListener(_onPlayerChanged);
    try {
      await player.initialize();
      await player.seekTo(Duration(milliseconds: _startMs));
      if (mounted && identical(player, _player)) setState(() => _ready = true);
    } catch (error, stack) {
      _diagnosticFailure = MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'playback',
      );
      player.removeListener(_onPlayerChanged);
      if (identical(player, _player)) _player = null;
      try {
        await player.dispose();
      } catch (error, stack) {
        MobileDiagnostics.instance.error(error, stack, operation: 'playback');
        /* Keep the failure UI available. */
      }
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _scrubTimer?.cancel();
    final player = _player;
    _player = null;
    player?.removeListener(_onPlayerChanged);
    unawaited(_guard(player?.dispose()));
    super.dispose();
  }

  void _playbackFailed(Object error, StackTrace? stack) {
    _diagnosticFailure = MobileDiagnostics.instance.error(
      error,
      stack,
      operation: 'playback',
    );
    if (mounted) {
      setState(() {
        _ready = false;
        _failed = true;
      });
    }
  }

  Future<void> _guard(Future<void>? action) async {
    try {
      await action;
    } catch (error, stack) {
      _playbackFailed(error, stack);
    }
  }

  void _onPlayerChanged() {
    final player = _player;
    if (player == null || !mounted) return;
    final value = player.value;
    if (value.hasError && !_failed) {
      _playbackFailed(
        StateError(value.errorDescription ?? 'playback_failed'),
        null,
      );
      return;
    }
    final next = value.position.inMilliseconds;
    if (_pendingScrubMs == null && (next - _positionMs).abs() >= 40) {
      setState(() => _positionMs = next);
    }
    if (_boundedPlayback && !_wrapping && value.isPlaying && next >= _endMs) {
      unawaited(_guard(_handleRangeEnd(player)));
    }
  }

  Future<void> _handleRangeEnd(VideoPlayerController player) async {
    _wrapping = true;
    try {
      if (_loopRange) {
        await player.seekTo(Duration(milliseconds: _startMs));
      } else {
        _boundedPlayback = false;
        await player.pause();
        await player.seekTo(Duration(milliseconds: _endMs));
        if (mounted) setState(() => _positionMs = _endMs);
      }
    } finally {
      _wrapping = false;
    }
  }

  Future<void> _seek(int position) async {
    final target = position.clamp(0, widget.durationMs).toInt();
    final player = _player;
    if (player == null || !mounted) return;
    setState(() => _positionMs = target);
    await player.seekTo(Duration(milliseconds: target));
  }

  /// Moves the playhead at once and throttles decoder seeks while dragging.
  void _scrubTo(int position) {
    final target = position.clamp(0, widget.durationMs).toInt();
    setState(() => _positionMs = target);
    _pendingScrubMs = target;
    if (_scrubTimer != null) return;
    unawaited(_guard(_seek(target)));
    _scrubTimer = Timer(const Duration(milliseconds: 120), () {
      _scrubTimer = null;
      final pending = _pendingScrubMs;
      if (pending != null && pending != target && mounted) _scrubTo(pending);
    });
  }

  void _finishScrub(int position) {
    _scrubTimer?.cancel();
    _scrubTimer = null;
    _pendingScrubMs = null;
    unawaited(_guard(_seek(position)));
  }

  Future<void> _pauseForEditing() async {
    final player = _player;
    if (player == null || !player.value.isPlaying) return;
    _boundedPlayback = false;
    await player.pause();
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (player == null || !_ready) return;
    if (player.value.isPlaying) {
      _boundedPlayback = false;
      await player.pause();
      if (mounted) setState(() {});
      return;
    }
    const tolerance = 200;
    if (_positionMs >= _startMs && _positionMs < _endMs - tolerance) {
      _boundedPlayback = true;
    } else if (_positionMs < _startMs - tolerance ||
        _positionMs > _endMs + tolerance) {
      _boundedPlayback = false;
    } else {
      await _seek(_startMs);
      _boundedPlayback = true;
    }
    _loopRange = true;
    await player.play();
    if (mounted) setState(() {});
  }

  Future<void> _previewEnding() async {
    final player = _player;
    if (player == null || !_ready) return;
    await player.pause();
    await _seek((_endMs - 3000).clamp(_startMs, _endMs).toInt());
    _boundedPlayback = true;
    _loopRange = false;
    await player.play();
    if (mounted) setState(() {});
  }

  void _setRange(int startMs, int endMs, {bool expandWindow = true}) {
    setState(() {
      _startMs = startMs;
      _endMs = endMs;
      // Button edits may need a wider axis. Dragging keeps its axis stable,
      // or the handle would move away from the finger on every update.
      if (expandWindow) {
        if (startMs < _windowStartMs + 1000) {
          _windowStartMs = (startMs - _windowStepMs).clamp(0, startMs).toInt();
        }
        if (endMs > _windowEndMs - 1000) {
          _windowEndMs = (endMs + _windowStepMs)
              .clamp(endMs, widget.durationMs)
              .toInt();
        }
      }
    });
  }

  void _onTimelineRangeChanged(ClipRangeHandle handle, int startMs, int endMs) {
    if (_player?.value.isPlaying == true) unawaited(_guard(_pauseForEditing()));
    _setRange(startMs, endMs, expandWindow: false);
    _scrubTo(handle == ClipRangeHandle.start ? startMs : endMs);
  }

  void _onTimelineRangeChangeEnd(ClipRangeHandle handle) {
    _finishScrub(handle == ClipRangeHandle.start ? _startMs : _endMs);
  }

  void _extendWindow(ClipRangeHandle handle) {
    setState(() {
      if (handle == ClipRangeHandle.start) {
        _windowStartMs = (_windowStartMs - _windowStepMs)
            .clamp(0, _windowStartMs)
            .toInt();
      } else {
        _windowEndMs = (_windowEndMs + _windowStepMs)
            .clamp(_windowEndMs, widget.durationMs)
            .toInt();
      }
    });
  }

  void _nudge(ClipRangeHandle handle, int deltaMs) {
    if (handle == ClipRangeHandle.start) {
      final start = (_startMs + deltaMs).clamp(0, _endMs - _minClipMs).toInt();
      _setRange(start, _endMs);
      _finishScrub(start);
    } else {
      final end = (_endMs + deltaMs)
          .clamp(_startMs + _minClipMs, widget.durationMs)
          .toInt();
      _setRange(_startMs, end);
      _finishScrub(end);
    }
  }

  void _extendBoth() {
    _setRange(
      (_startMs - 2000).clamp(0, _startMs).toInt(),
      (_endMs + 2000).clamp(_endMs, widget.durationMs).toInt(),
    );
  }

  /// Sets one end at the playhead. A playhead beyond the other end slides the
  /// clip there and keeps its length.
  void _setHandleAtPosition(ClipRangeHandle handle) {
    final position = _positionMs.clamp(0, widget.durationMs).toInt();
    final length = _endMs - _startMs;
    if (handle == ClipRangeHandle.start) {
      if (position <= _endMs - _minClipMs) {
        _setRange(position, _endMs);
      } else {
        final end = (position + length).clamp(position, widget.durationMs);
        _setRange((end - length).clamp(0, position).toInt(), end.toInt());
      }
    } else {
      if (position >= _startMs + _minClipMs) {
        _setRange(_startMs, position);
      } else {
        final start = (position - length).clamp(0, position).toInt();
        _setRange(
          start,
          (start + length).clamp(position, widget.durationMs).toInt(),
        );
      }
    }
  }

  void _restoreDefault() {
    _setRange(
      widget.defaultStartMs ?? widget.startMs,
      widget.defaultEndMs ?? widget.endMs,
    );
    unawaited(_guard(_seek(_startMs)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = _player;
    final playing = player?.value.isPlaying == true;
    final hasDefault =
        widget.defaultStartMs != null &&
        widget.defaultEndMs != null &&
        (widget.defaultStartMs != _startMs || widget.defaultEndMs != _endMs);
    final changed = _startMs != widget.startMs || _endMs != widget.endMs;
    final labelStyle = theme.textTheme.bodySmall;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 34,
                  height: 3,
                  decoration: BoxDecoration(
                    color: BhePalette.textTertiary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: context.bheText('取消'),
                    icon: const Icon(LucideIcons.x, size: 19),
                  ),
                ],
              ),
              if (widget.description != null)
                Text(context.bheText(widget.description!), style: labelStyle),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => unawaited(_guard(_togglePlayback())),
                child: AspectRatio(
                  aspectRatio: widget.aspectRatio,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ColoredBox(
                      color: Colors.black,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_ready && player != null) VideoPlayer(player),
                          if (!_ready)
                            _failed
                                ? const VideoUnavailablePlaceholder()
                                : const Center(
                                    child: CircularProgressIndicator(),
                                  ),
                          if (_ready && !playing)
                            const Center(
                              child: Icon(
                                LucideIcons.play,
                                size: 42,
                                color: Colors.white70,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              if (_failed &&
                  widget.onFeedback != null &&
                  _diagnosticFailure != null)
                TextButton(
                  onPressed: () => widget.onFeedback!(_diagnosticFailure!),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: Text(context.bheText('反馈')),
                ),
              Row(
                children: [
                  IconButton(
                    key: const Key('clip-range-play'),
                    tooltip: context.bheText(playing ? '暂停' : '播放片段'),
                    onPressed: _ready
                        ? () => unawaited(_guard(_togglePlayback()))
                        : null,
                    icon: Icon(playing ? LucideIcons.pause : LucideIcons.play),
                  ),
                  TextButton.icon(
                    key: const Key('clip-range-preview-ending'),
                    onPressed: _ready
                        ? () => unawaited(_guard(_previewEnding()))
                        : null,
                    icon: const Icon(LucideIcons.skipForward, size: 16),
                    label: Text(context.bheText('预览结尾')),
                  ),
                  const Spacer(),
                  Text(
                    context.bheText('当前 ${formatRangeMs(_positionMs)}'),
                    style: labelStyle,
                  ),
                ],
              ),
              ClipRangeTimeline(
                key: const Key('clip-range-timeline'),
                windowStartMs: _windowStartMs,
                windowEndMs: _windowEndMs,
                startMs: _startMs,
                endMs: _endMs,
                positionMs: _positionMs,
                eventMs: widget.eventMs,
                originalStartMs: widget.startMs,
                originalEndMs: widget.endMs,
                enabled: _ready,
                minDurationMs: _minClipMs,
                semanticLabel: context.bheText('片段时间轴'),
                onRangeChanged: _onTimelineRangeChanged,
                onRangeChangeEnd: _onTimelineRangeChangeEnd,
                onScrub: _scrubTo,
                onScrubEnd: _finishScrub,
                onExtendWindow: _extendWindow,
              ),
              Row(
                children: [
                  Text(
                    formatRangeMs(_windowStartMs),
                    style: labelStyle?.copyWith(color: BhePalette.textTertiary),
                  ),
                  const Spacer(),
                  if (widget.eventMs != null) ...[
                    const Icon(
                      Icons.arrow_drop_down,
                      size: 16,
                      color: BhePalette.warning,
                    ),
                    Text(
                      context.bheText('进球时刻'),
                      style: labelStyle?.copyWith(
                        color: BhePalette.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (changed)
                    Text(
                      '┄ ${context.bheText('原范围')}',
                      style: labelStyle?.copyWith(
                        color: BhePalette.textTertiary,
                      ),
                    ),
                  const Spacer(),
                  Text(
                    formatRangeMs(_windowEndMs),
                    style: labelStyle?.copyWith(color: BhePalette.textTertiary),
                  ),
                ],
              ),
              Text(
                context.bheText('拖动两端调整范围，点时间轴跳到该位置。'),
                style: labelStyle?.copyWith(color: BhePalette.textTertiary),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _HandleEditor(
                      keyPrefix: 'clip-range-start',
                      label: context.bheText('开始'),
                      valueMs: _startMs,
                      setHereLabel: context.bheText('设为开始'),
                      enabled: _ready,
                      onNudge: (delta) => _nudge(ClipRangeHandle.start, delta),
                      onSetHere: () =>
                          _setHandleAtPosition(ClipRangeHandle.start),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _HandleEditor(
                      keyPrefix: 'clip-range-end',
                      label: context.bheText('结束'),
                      valueMs: _endMs,
                      setHereLabel: context.bheText('设为结束'),
                      enabled: _ready,
                      onNudge: (delta) => _nudge(ClipRangeHandle.end, delta),
                      onSetHere: () =>
                          _setHandleAtPosition(ClipRangeHandle.end),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ActionChip(
                    key: const Key('clip-range-extend-start'),
                    label: Text(context.bheText('开头 −2 秒')),
                    onPressed: () => _nudge(ClipRangeHandle.start, -2000),
                  ),
                  ActionChip(
                    key: const Key('clip-range-extend-end'),
                    label: Text(context.bheText('结尾 +2 秒')),
                    onPressed: () => _nudge(ClipRangeHandle.end, 2000),
                  ),
                  ActionChip(
                    key: const Key('clip-range-extend-both'),
                    label: Text(context.bheText('前后各 +2 秒')),
                    onPressed: _extendBoth,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  if (hasDefault)
                    TextButton(
                      key: const Key('clip-range-restore'),
                      onPressed: _restoreDefault,
                      child: Text(context.bheText('恢复默认')),
                    ),
                  const Spacer(),
                  Text(
                    '${formatRangeMs(_startMs)} – ${formatRangeMs(_endMs)} · ${((_endMs - _startMs) / 1000).toStringAsFixed(1)}s',
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('clip-range-apply'),
                onPressed: () =>
                    Navigator.pop(context, (start: _startMs, end: _endMs)),
                icon: Icon(widget.confirmIcon, size: 18),
                label: Text(widget.confirmLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HandleEditor extends StatelessWidget {
  const _HandleEditor({
    required this.keyPrefix,
    required this.label,
    required this.valueMs,
    required this.setHereLabel,
    required this.enabled,
    required this.onNudge,
    required this.onSetHere,
  });

  final String keyPrefix;
  final String label;
  final int valueMs;
  final String setHereLabel;
  final bool enabled;
  final ValueChanged<int> onNudge;
  final VoidCallback onSetHere;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        border: Border.all(color: BhePalette.borderStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              const Spacer(),
              Text(
                formatRangeMs(valueMs),
                key: Key('$keyPrefix-value'),
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final delta in const [-1000, -500, 500, 1000])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: OutlinedButton(
                      key: Key('$keyPrefix-nudge-$delta'),
                      onPressed: enabled ? () => onNudge(delta) : null,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: EdgeInsets.zero,
                        side: const BorderSide(color: BhePalette.border),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      child: Text(
                        '${delta > 0 ? '+' : '−'}${delta.abs() == 500 ? '.5' : '1'}',
                      ),
                    ),
                  ),
                ),
            ],
          ),
          TextButton(
            key: Key('$keyPrefix-set-here'),
            onPressed: enabled ? onSetHere : null,
            style: TextButton.styleFrom(minimumSize: const Size(0, 34)),
            child: Text(setHereLabel),
          ),
        ],
      ),
    );
  }
}

/// `m:ss.s`, precise enough for half-second nudges.
String formatRangeMs(int ms) {
  final tenths = (ms / 100).round();
  final seconds = tenths ~/ 10;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}.${tenths % 10}';
}

/// Range editor axis: the clip block, its two handles, the playhead, the shot
/// moment and the range the editor opened with, on one scrubbable track.
/// Ported from the desktop timeline with finger-sized hit areas.
class ClipRangeTimeline extends StatefulWidget {
  const ClipRangeTimeline({
    super.key,
    required this.windowStartMs,
    required this.windowEndMs,
    required this.startMs,
    required this.endMs,
    required this.positionMs,
    required this.enabled,
    required this.onRangeChanged,
    required this.onRangeChangeEnd,
    required this.onScrub,
    required this.onScrubEnd,
    required this.onExtendWindow,
    this.eventMs,
    this.originalStartMs,
    this.originalEndMs,
    this.minDurationMs = 1000,
    this.semanticLabel,
  });

  final int windowStartMs;
  final int windowEndMs;
  final int startMs;
  final int endMs;
  final int positionMs;
  final bool enabled;
  final int? eventMs;
  final int? originalStartMs;
  final int? originalEndMs;
  final int minDurationMs;
  final String? semanticLabel;
  final void Function(ClipRangeHandle handle, int startMs, int endMs)
  onRangeChanged;
  final ValueChanged<ClipRangeHandle> onRangeChangeEnd;
  final ValueChanged<int> onScrub;
  final ValueChanged<int> onScrubEnd;
  final ValueChanged<ClipRangeHandle> onExtendWindow;

  static const double height = 56;
  static const double padding = 14;
  static const double edgeZone = 20;
  static const double handleSlop = 24;

  @override
  State<ClipRangeTimeline> createState() => _ClipRangeTimelineState();
}

enum _DragTarget { start, end, playhead }

class _ClipRangeTimelineState extends State<ClipRangeTimeline> {
  _DragTarget? _drag;
  double _pointerX = 0;
  double _width = 0;
  Timer? _edgeTimer;

  @override
  void dispose() {
    _edgeTimer?.cancel();
    super.dispose();
  }

  int get _span =>
      (widget.windowEndMs - widget.windowStartMs).clamp(1, 1 << 40).toInt();

  double _xAt(int ms) {
    final usable = _width - ClipRangeTimeline.padding * 2;
    final ratio = (ms - widget.windowStartMs) / _span;
    return ClipRangeTimeline.padding + ratio.clamp(0.0, 1.0) * usable;
  }

  int _msAt(double x) {
    final usable = (_width - ClipRangeTimeline.padding * 2).clamp(1.0, 1e9);
    final ratio = ((x - ClipRangeTimeline.padding) / usable).clamp(0.0, 1.0);
    return (widget.windowStartMs + ratio * _span).round();
  }

  _DragTarget _targetAt(double x) {
    final startDistance = (x - _xAt(widget.startMs)).abs();
    final endDistance = (x - _xAt(widget.endMs)).abs();
    if (startDistance <= ClipRangeTimeline.handleSlop ||
        endDistance <= ClipRangeTimeline.handleSlop) {
      return startDistance <= endDistance ? _DragTarget.start : _DragTarget.end;
    }
    return _DragTarget.playhead;
  }

  void _applyDrag() {
    final ms = _msAt(_pointerX);
    switch (_drag) {
      case _DragTarget.start:
        final start = ms
            .clamp(widget.windowStartMs, widget.endMs - widget.minDurationMs)
            .toInt();
        widget.onRangeChanged(ClipRangeHandle.start, start, widget.endMs);
      case _DragTarget.end:
        final end = ms
            .clamp(widget.startMs + widget.minDurationMs, widget.windowEndMs)
            .toInt();
        widget.onRangeChanged(ClipRangeHandle.end, widget.startMs, end);
      case _DragTarget.playhead:
        widget.onScrub(ms);
      case null:
        break;
    }
  }

  void _updateEdgeTimer() {
    final atStartEdge =
        _drag == _DragTarget.start &&
        _pointerX <= ClipRangeTimeline.padding + ClipRangeTimeline.edgeZone;
    final atEndEdge =
        _drag == _DragTarget.end &&
        _pointerX >=
            _width - ClipRangeTimeline.padding - ClipRangeTimeline.edgeZone;
    if (!atStartEdge && !atEndEdge) {
      _edgeTimer?.cancel();
      _edgeTimer = null;
      return;
    }
    _edgeTimer ??= Timer.periodic(const Duration(milliseconds: 220), (_) {
      if (!mounted || _drag == null) return;
      // Pin the handle to the already widened edge, then widen once more.
      _applyDrag();
      widget.onExtendWindow(
        _drag == _DragTarget.start
            ? ClipRangeHandle.start
            : ClipRangeHandle.end,
      );
    });
  }

  void _onDragStart(Offset position) {
    _pointerX = position.dx;
    _drag = _targetAt(position.dx);
    _applyDrag();
  }

  void _onDragUpdate(Offset position) {
    if (_drag == null) return;
    _pointerX = position.dx;
    _applyDrag();
    _updateEdgeTimer();
  }

  void _onDragEnd() {
    final drag = _drag;
    _drag = null;
    _edgeTimer?.cancel();
    _edgeTimer = null;
    switch (drag) {
      case _DragTarget.start:
        widget.onRangeChangeEnd(ClipRangeHandle.start);
      case _DragTarget.end:
        widget.onRangeChangeEnd(ClipRangeHandle.end);
      case _DragTarget.playhead:
        widget.onScrubEnd(_msAt(_pointerX));
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Pick the handle under the finger, not where the drag slop ends.
            dragStartBehavior: DragStartBehavior.down,
            onTapUp: widget.enabled
                ? (details) {
                    final ms = _msAt(details.localPosition.dx);
                    widget.onScrub(ms);
                    widget.onScrubEnd(ms);
                  }
                : null,
            onHorizontalDragStart: widget.enabled
                ? (details) => _onDragStart(details.localPosition)
                : null,
            onHorizontalDragUpdate: widget.enabled
                ? (details) => _onDragUpdate(details.localPosition)
                : null,
            onHorizontalDragEnd: widget.enabled ? (_) => _onDragEnd() : null,
            onHorizontalDragCancel: widget.enabled ? _onDragEnd : null,
            child: CustomPaint(
              size: Size(constraints.maxWidth, ClipRangeTimeline.height),
              painter: _TimelinePainter(
                startX: _xAt(widget.startMs),
                endX: _xAt(widget.endMs),
                playheadX: _xAt(widget.positionMs),
                playheadVisible:
                    widget.positionMs >= widget.windowStartMs &&
                    widget.positionMs <= widget.windowEndMs,
                playheadInside:
                    widget.positionMs >= widget.startMs &&
                    widget.positionMs <= widget.endMs,
                eventX:
                    widget.eventMs == null ||
                        widget.eventMs! < widget.windowStartMs ||
                        widget.eventMs! > widget.windowEndMs
                    ? null
                    : _xAt(widget.eventMs!),
                originalStartX: widget.originalStartMs == null
                    ? null
                    : _xAt(widget.originalStartMs!),
                originalEndX: widget.originalEndMs == null
                    ? null
                    : _xAt(widget.originalEndMs!),
                originalChanged:
                    widget.originalStartMs != widget.startMs ||
                    widget.originalEndMs != widget.endMs,
                enabled: widget.enabled,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.startX,
    required this.endX,
    required this.playheadX,
    required this.playheadVisible,
    required this.playheadInside,
    required this.eventX,
    required this.originalStartX,
    required this.originalEndX,
    required this.originalChanged,
    required this.enabled,
  });

  final double startX;
  final double endX;
  final double playheadX;
  final bool playheadVisible;
  final bool playheadInside;
  final double? eventX;
  final double? originalStartX;
  final double? originalEndX;
  final bool originalChanged;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = ClipRangeTimeline.padding;
    const trackTop = 14.0;
    final trackBottom = size.height - 12;
    final accent = enabled ? BhePalette.orange : BhePalette.textTertiary;

    canvas.drawRRect(
      RRect.fromLTRBR(
        pad,
        trackTop + 10,
        size.width - pad,
        trackBottom - 10,
        const Radius.circular(3),
      ),
      Paint()..color = BhePalette.surface3,
    );

    final block = RRect.fromLTRBR(
      startX,
      trackTop,
      endX,
      trackBottom,
      const Radius.circular(5),
    );
    canvas.drawRRect(block, Paint()..color = accent.withValues(alpha: 0.22));
    canvas.drawRRect(
      block,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final originalStart = originalStartX;
    final originalEnd = originalEndX;
    if (originalChanged && originalStart != null && originalEnd != null) {
      final paint = Paint()
        ..color = BhePalette.textSecondary
        ..strokeWidth = 2;
      final y = size.height - 3;
      for (var x = originalStart; x < originalEnd; x += 7) {
        canvas.drawLine(
          Offset(x, y),
          Offset((x + 4).clamp(x, originalEnd), y),
          paint,
        );
      }
    }

    final event = eventX;
    if (event != null) {
      canvas.drawPath(
        Path()
          ..moveTo(event - 6, 2)
          ..lineTo(event + 6, 2)
          ..lineTo(event, 11)
          ..close(),
        Paint()..color = BhePalette.warning,
      );
      canvas.drawLine(
        Offset(event, trackTop),
        Offset(event, trackBottom),
        Paint()
          ..color = BhePalette.warning.withValues(alpha: 0.7)
          ..strokeWidth = 1,
      );
    }

    for (final x in [startX, endX]) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          x - 6,
          trackTop - 3,
          x + 6,
          trackBottom + 3,
          const Radius.circular(4),
        ),
        Paint()..color = accent,
      );
      final grip = Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..strokeWidth = 1.2;
      final mid = (trackTop + trackBottom) / 2;
      canvas.drawLine(Offset(x - 2, mid - 6), Offset(x - 2, mid + 6), grip);
      canvas.drawLine(Offset(x + 2, mid - 6), Offset(x + 2, mid + 6), grip);
    }

    if (playheadVisible) {
      final color = playheadInside ? BhePalette.text : BhePalette.warning;
      canvas.drawLine(
        Offset(playheadX, trackTop - 4),
        Offset(playheadX, trackBottom + 4),
        Paint()
          ..color = color
          ..strokeWidth = 2,
      );
      canvas.drawCircle(
        Offset(playheadX, trackTop - 5),
        4,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.startX != startX ||
      old.endX != endX ||
      old.playheadX != playheadX ||
      old.playheadVisible != playheadVisible ||
      old.playheadInside != playheadInside ||
      old.eventX != eventX ||
      old.originalStartX != originalStartX ||
      old.originalEndX != originalEndX ||
      old.originalChanged != originalChanged ||
      old.enabled != enabled;
}
