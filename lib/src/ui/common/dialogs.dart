import 'package:flutter/material.dart';

import '../theme.dart';

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'OK',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: context.colors.error, foregroundColor: context.colors.onError)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String initialValue,
  String? label,
  String confirmLabel = 'Save',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) =>
        _TextInputDialog(title: title, initialValue: initialValue, label: label, confirmLabel: confirmLabel),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({required this.title, required this.initialValue, this.label, required this.confirmLabel});

  final String title;
  final String initialValue;
  final String? label;
  final String confirmLabel;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialValue)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initialValue.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      Navigator.pop(context, text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(labelText: widget.label),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// Shows [builder] as a bottom sheet on phones and as a dialog on larger windows.
Future<T?> showAdaptiveSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, ScrollController? scrollController) builder,
  bool asSheet = false,
  double maxDialogWidth = 560,
}) {
  if (asSheet) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 1,
        builder: (context, scrollController) => builder(context, scrollController),
      ),
    );
  }

  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxDialogWidth, maxHeight: 720),
        child: builder(context, null),
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: colors.secondaryContainer, shape: BoxShape.circle),
              child: Icon(icon, size: 34, color: colors.onSecondaryContainer),
            ),
            const SizedBox(height: 16),
            Text(title, style: context.text.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
