import 'package:flutter/widgets.dart';

/// Places the video and its annotations in one centered coordinate space that
/// shows the full frame (contain): the box keeps the video's display aspect
/// and never grows beyond the viewport, so portrait sources are letterboxed
/// instead of cropped.
class ReviewVideoViewport extends StatelessWidget {
  const ReviewVideoViewport({
    super.key,
    required this.frameSize,
    required this.child,
  });

  final Size frameSize;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final aspect = frameSize.width > 0 && frameSize.height > 0
          ? frameSize.width / frameSize.height
          : 16 / 9;
      var width = constraints.maxWidth;
      var height = width / aspect;
      if (height > constraints.maxHeight) {
        height = constraints.maxHeight;
        width = height * aspect;
      }
      return Center(
        child: SizedBox(width: width, height: height, child: child),
      );
    },
  );
}
