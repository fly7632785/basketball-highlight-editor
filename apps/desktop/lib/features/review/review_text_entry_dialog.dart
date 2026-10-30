import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

Future<String?> promptReviewPlayerName(BuildContext context) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => ReviewTextEntryDialog(
      title: context.bheText('添加球员'),
      hintText: context.bheText('例如：科比、罗斯'),
      confirmLabel: context.bheText('添加'),
    ),
  );
  return name?.trim().isEmpty == true ? null : name?.trim();
}

/// The same name/note entry used by both review subpages.
class ReviewTextEntryDialog extends StatefulWidget {
  const ReviewTextEntryDialog({
    super.key,
    required this.title,
    required this.hintText,
    required this.confirmLabel,
    this.initialText = '',
    this.maxLines = 1,
  });

  final String title;
  final String hintText;
  final String confirmLabel;
  final String initialText;
  final int maxLines;

  @override
  State<ReviewTextEntryDialog> createState() => _ReviewTextEntryDialogState();
}

class _ReviewTextEntryDialogState extends State<ReviewTextEntryDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AlertDialog(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        side: BorderSide(color: c.borderStrong),
      ),
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: widget.maxLines,
        decoration: InputDecoration(
          hintText: widget.hintText,
          border: widget.maxLines > 1 ? const OutlineInputBorder() : null,
        ),
        onSubmitted: widget.maxLines == 1 ? (_) => _submit() : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.bheText('取消')),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
