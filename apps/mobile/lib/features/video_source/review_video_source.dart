part of '../../mobile_ui.dart';

Future<void> _loadReviewVideo(_ReviewViewState view) async {
  final state = view.state;
  final path = view._openedVideoPath = state.project.video?.path;
  view._openedSourceRevision = state.videoSourceRevision;
  final generation = ++view._videoOpenGeneration;
  final projectId = state.project.id;
  bool current() =>
      view.mounted &&
      generation == view._videoOpenGeneration &&
      state.project.id == projectId;
  final next = path == null
      ? null
      : await openSourceVideo(
          path,
          isCurrent: current,
          onFailure: state.markVideoFailure,
        );
  if (!current()) {
    await disposeSourceVideo(next);
    return;
  }
  next?.addListener(view._videoChanged);
  final previous = view.controller;
  view._installSourcePlayer(next);
  await disposeSourceVideo(previous);
  if (next != null && current() && view.candidates.isNotEmpty) {
    try {
      await view._replay(view.candidates.first);
    } catch (error, stack) {
      final diagnostic = MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'playback',
      );
      if (current()) {
        state.markVideoFailure(
          VideoSourceFailure.unplayable,
          diagnostic: diagnostic,
        );
      }
    }
  }
}

class _ReviewSourceBody extends StatelessWidget {
  const _ReviewSourceBody({
    required this.rail,
    required this.video,
    required this.hasReviewFooter,
  });
  final Widget rail;
  final Widget video;
  final bool hasReviewFooter;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Reserve space for the tabs and a candidate on short portrait screens.
      final railHeight = math.max(
        constraints.maxHeight * .4,
        math.min(hasReviewFooter ? 192.0 : 144.0, constraints.maxHeight),
      );
      return Column(
        children: [
          SizedBox(height: railHeight, child: rail),
          Expanded(child: video),
        ],
      );
    },
  );
}
