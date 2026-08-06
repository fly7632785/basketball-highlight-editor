// lib/components/cs_progress_track.dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/tokens.dart';

class CsProgressTrack extends StatelessWidget {
  const CsProgressTrack({this.value, this.indeterminate = false, super.key});
  final double? value;
  final bool indeterminate;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(CsRadius.full),
      child: LinearProgressIndicator(
        value: indeterminate ? null : value,
        minHeight: 6,
        backgroundColor: c.surface3,
        valueColor: AlwaysStoppedAnimation<Color>(c.indigo),
      ),
    );
  }
}
