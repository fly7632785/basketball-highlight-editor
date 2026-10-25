import 'dart:ui';

Rect? recommendedNetRoi(Rect? analysisRoi, Rect? hoopBbox) {
  if (analysisRoi == null) return null;
  if (hoopBbox == null) {
    return Rect.fromLTRB(
      (analysisRoi.left + analysisRoi.width * 0.30).clamp(0.0, 1.0),
      (analysisRoi.top + analysisRoi.height * 0.38).clamp(0.0, 1.0),
      (analysisRoi.right - analysisRoi.width * 0.30).clamp(0.0, 1.0),
      (analysisRoi.top + analysisRoi.height * 0.74).clamp(0.0, 1.0),
    );
  }
  final rimY = hoopBbox.center.dy - hoopBbox.height * 0.28;
  final rimHeight = hoopBbox.height * 0.45;
  final width = (hoopBbox.width * 1.5)
      .clamp(analysisRoi.width * 0.08, analysisRoi.width * 0.34)
      .toDouble();
  final left = (hoopBbox.center.dx - width / 2)
      .clamp(analysisRoi.left, analysisRoi.right - width)
      .toDouble();
  // Start at the physical rim's upper edge so the net region touches the
  // hoop; keep the previous lower boundary for the same detection coverage.
  final top = (rimY - rimHeight / 2)
      .clamp(analysisRoi.top, analysisRoi.bottom)
      .toDouble();
  final bottom = (top + rimHeight * 4.5)
      .clamp(top, analysisRoi.bottom)
      .toDouble();
  return Rect.fromLTRB(left, top, left + width, bottom);
}
