part of '../../mobile_ui.dart';

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({
    super.key,
    required this.path,
    required this.aspectRatio,
    this.sourceRevision = 0,
    this.unavailable = false,
    this.onFailure,
    this.seekStepMs = 1500,
    this.initialPositionMs,
    this.requestedPositionMs,
    this.stopAtMs,
    this.onPositionChanged,
  });
  final String path;
  final int sourceRevision;
  final bool unavailable;
  final void Function(VideoSourceFailure, {DiagnosticErrorRecord? diagnostic})?
  onFailure;
  final double aspectRatio;
  final int seekStepMs;
  final int? initialPositionMs;
  final int? requestedPositionMs;
  final int? stopAtMs;
  final ValueChanged<int>? onPositionChanged;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? controller;
  Future<void> _playerQueue = Future<void>.value();
  Future<void>? _playerInitialization;
  int _playerGeneration = 0;
  int _lastReportedPosition = -1;
  bool _positionCallbackScheduled = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _startPlayer(widget.path, widget.initialPositionMs);
  }

  @override
  void didUpdateWidget(covariant _VideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.path != oldWidget.path ||
        widget.sourceRevision != oldWidget.sourceRevision ||
        widget.unavailable != oldWidget.unavailable) {
      unawaited(_replacePlayer());
      return;
    }
    final position = widget.requestedPositionMs;
    if (position != null && position != oldWidget.requestedPositionMs) {
      unawaited(_seekTo(position));
    }
  }

  @override
  void dispose() {
    _playerGeneration++;
    controller?.removeListener(_changed);
    final player = controller;
    controller = null;
    _failed = false;
    final queue = _playerQueue;
    final initialization = _playerInitialization;
    _playerQueue = Future<void>.value();
    _playerInitialization = null;
    unawaited(() async {
      await queue;
      await initialization;
      await _releasePlayer(player);
    }());
    super.dispose();
  }

  void _startPlayer(String path, int? initialPositionMs) {
    if (widget.unavailable) return;
    _failed = false;
    final generation = ++_playerGeneration;
    final player = sourceVideoController(path);
    controller = player;
    player.addListener(_changed);
    _playerInitialization = _initializePlayer(
      player,
      generation,
      initialPositionMs,
    );
    unawaited(_playerInitialization!);
  }

  Future<void> _initializePlayer(
    VideoPlayerController player,
    int generation,
    int? initialPositionMs,
  ) async {
    try {
      await player.initialize();
      if (initialPositionMs != null) {
        await player.seekTo(Duration(milliseconds: initialPositionMs));
      }
      if (!mounted || generation != _playerGeneration || controller != player) {
        return;
      }
      setState(() {});
    } catch (error, stack) {
      final diagnostic = MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'playback',
      );
      if (generation != _playerGeneration || controller != player) return;
      player.removeListener(_changed);
      controller = null;
      _failed = true;
      await _releasePlayer(player);
      if (!mounted || generation != _playerGeneration) return;
      setState(() {});
      widget.onFailure?.call(
        VideoSourceFailure.unplayable,
        diagnostic: diagnostic,
      );
    }
  }

  Future<void> _releasePlayer(VideoPlayerController? player) async {
    try {
      await player?.dispose();
    } catch (error, stack) {
      MobileDiagnostics.instance.error(error, stack, operation: 'playback');
      // A failed platform cleanup must not strand the replacement preview.
    }
  }

  Future<void> _replacePlayer() async {
    final generation = ++_playerGeneration;
    final previous = controller;
    final initialization = _playerInitialization;
    previous?.removeListener(_changed);
    controller = null;
    _failed = false;
    final queue = _playerQueue;
    _playerQueue = Future<void>.value();
    _playerInitialization = null;
    if (mounted) setState(() {});
    await queue;
    await initialization;
    await _releasePlayer(previous);
    if (!mounted || generation != _playerGeneration) return;
    _startPlayer(widget.path, widget.initialPositionMs);
  }

  void _changed() {
    final player = controller;
    final stopAt = widget.stopAtMs;
    if (player?.value.hasError == true && !_failed) {
      _failed = true;
      final diagnostic = MobileDiagnostics.instance.error(
        StateError(player?.value.errorDescription ?? 'playback_failed'),
        null,
        operation: 'playback',
      );
      final generation = _playerGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            generation == _playerGeneration &&
            controller == player) {
          widget.onFailure?.call(
            VideoSourceFailure.unplayable,
            diagnostic: diagnostic,
          );
        }
      });
    }
    if (player?.value.isInitialized == true &&
        stopAt != null &&
        player!.value.isPlaying &&
        player.value.position.inMilliseconds >= stopAt) {
      unawaited(_enqueuePlayer((player) => player.pause()));
    }
    final position = player?.value.position.inMilliseconds;
    if (position != null && (position - _lastReportedPosition).abs() >= 100) {
      _lastReportedPosition = position;
      if (widget.onPositionChanged != null && !_positionCallbackScheduled) {
        _positionCallbackScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _positionCallbackScheduled = false;
          if (!mounted) return;
          widget.onPositionChanged?.call(
            controller?.value.position.inMilliseconds ?? position,
          );
        });
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    await _enqueuePlayer((player) async {
      if (player.value.isPlaying) {
        await player.pause();
      } else {
        await player.play();
      }
    });
  }

  Future<void> _seek(int milliseconds) async {
    await _enqueuePlayer((player) async {
      final next = player.value.position + Duration(milliseconds: milliseconds);
      final bounded = next < Duration.zero
          ? Duration.zero
          : next > player.value.duration
          ? player.value.duration
          : next;
      await player.seekTo(bounded);
    });
  }

  Future<void> _seekTo(int milliseconds) async {
    await _enqueuePlayer(
      (player) => player.seekTo(Duration(milliseconds: milliseconds)),
    );
  }

  Future<void> _replay() async {
    await _enqueuePlayer((player) async {
      await player.seekTo(Duration.zero);
      await player.play();
    });
  }

  Future<void> _enqueuePlayer(
    Future<void> Function(VideoPlayerController player) action,
  ) {
    final task = _playerQueue.then((_) async {
      final player = controller;
      if (player == null || !player.value.isInitialized) return;
      try {
        await action(player);
      } catch (error, stack) {
        final diagnostic = MobileDiagnostics.instance.error(
          error,
          stack,
          operation: 'playback',
        );
        final generation = _playerGeneration;
        if (mounted && controller == player) {
          setState(() => _failed = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                generation == _playerGeneration &&
                controller == player) {
              widget.onFailure?.call(
                VideoSourceFailure.unplayable,
                diagnostic: diagnostic,
              );
            }
          });
        }
      }
    });
    _playerQueue = task.then<void>((_) {}, onError: (_, _) {});
    return task;
  }

  @override
  Widget build(BuildContext context) {
    final player = controller;
    final ratio = widget.aspectRatio.isFinite && widget.aspectRatio > 0
        ? widget.aspectRatio
        : 16 / 9;
    final unavailable =
        widget.unavailable || _failed || player?.value.hasError == true;
    final initialized = !unavailable && player?.value.isInitialized == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
          child: AspectRatio(
            aspectRatio: ratio,
            child: ColoredBox(
              color: Colors.black,
              child: initialized
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        GestureDetector(
                          onTap: _toggle,
                          child: VideoPlayer(player!),
                        ),
                        IgnorePointer(
                          child: Align(
                            alignment: Alignment.center,
                            child: AnimatedOpacity(
                              opacity: player.value.isPlaying ? .18 : .9,
                              duration: const Duration(milliseconds: 150),
                              child: Icon(
                                player.value.isPlaying
                                    ? LucideIcons.pause
                                    : LucideIcons.play,
                                color: Colors.white,
                                size: 40,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : unavailable
                  ? const VideoUnavailablePlaceholder()
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
        if (initialized)
          Container(
            decoration: const BoxDecoration(
              color: BhePalette.surface3,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(9)),
            ),
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
            child: Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                  ),
                  child: Slider(
                    value: player!.value.position.inMilliseconds
                        .toDouble()
                        .clamp(
                          0,
                          player.value.duration.inMilliseconds.toDouble().clamp(
                            1,
                            double.infinity,
                          ),
                        ),
                    max: player.value.duration.inMilliseconds.toDouble().clamp(
                      1,
                      double.infinity,
                    ),
                    onChanged: (value) => _seekTo(value.round()),
                  ),
                ),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${_formatMs(player.value.position.inMilliseconds)} / ${_formatMs(player.value.duration.inMilliseconds)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _seek(-widget.seekStepMs),
                          icon: const Icon(LucideIcons.rotateCcw, size: 17),
                          tooltip:
                              '${context.bheText('后退')} ${context.bheText(_formatSeekStep(widget.seekStepMs))}',
                        ),
                        IconButton.filledTonal(
                          onPressed: _toggle,
                          icon: Icon(
                            player.value.isPlaying
                                ? LucideIcons.pause
                                : LucideIcons.play,
                            size: 18,
                          ),
                          tooltip: context.bheText('播放/暂停'),
                        ),
                        IconButton(
                          onPressed: () => _seek(widget.seekStepMs),
                          icon: const Icon(LucideIcons.rotateCw, size: 17),
                          tooltip:
                              '${context.bheText('前进')} ${context.bheText(_formatSeekStep(widget.seekStepMs))}',
                        ),
                        IconButton(
                          onPressed: _replay,
                          icon: const Icon(LucideIcons.refreshCw, size: 17),
                          tooltip: context.bheText('重播'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
