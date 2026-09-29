import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// A numeric text field with optional -/+ steppers. Values are committed while typing when they are
/// valid, and clamped into range when the field loses focus.
class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.hint,
    this.min,
    this.max,
    this.step = 1,
    this.decimals = 0,
    this.allowEmpty = false,
    this.enabled = true,
    this.showSteppers = true,
    this.suffixText,
    this.prefixIcon,
  });

  final num? value;
  final ValueChanged<num?> onChanged;
  final String? label;
  final String? hint;
  final num? min;
  final num? max;
  final num step;
  final int decimals;

  /// When true an empty field means "no value" (null), e.g. "use the project default".
  final bool allowEmpty;
  final bool enabled;
  final bool showSteppers;
  final String? suffixText;
  final Widget? prefixIcon;

  static String format(num? value, int decimals) {
    if (value == null) {
      return '';
    }

    if (decimals == 0) {
      return value.round().toString();
    }

    var text = value.toStringAsFixed(decimals);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '');
      if (text.endsWith('.')) {
        text = text.substring(0, text.length - 1);
      }
    }

    return text;
  }

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _controller = TextEditingController(
    text: NumberField.format(widget.value, widget.decimals),
  );
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final text = NumberField.format(widget.value, widget.decimals);
    if (!_focusNode.hasFocus && _controller.text != text) {
      _controller.text = text;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  num? _parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final parsed = num.tryParse(trimmed);
    if (parsed == null || parsed.isNaN || parsed.isInfinite) {
      return null;
    }

    return widget.decimals == 0 ? parsed.round() : parsed;
  }

  num _clamp(num value) {
    var result = value;
    if (widget.min != null && result < widget.min!) {
      result = widget.min!;
    }

    if (widget.max != null && result > widget.max!) {
      result = widget.max!;
    }

    return result;
  }

  bool _inRange(num value) =>
      (widget.min == null || value >= widget.min!) && (widget.max == null || value <= widget.max!);

  void _onTextChanged(String text) {
    if (text.trim().isEmpty) {
      if (widget.allowEmpty) {
        widget.onChanged(null);
      }

      return;
    }

    final parsed = _parse(text);
    if (parsed != null && _inRange(parsed)) {
      widget.onChanged(parsed);
    }
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      return;
    }

    final parsed = _parse(_controller.text);
    num? committed;
    if (parsed == null) {
      committed = widget.allowEmpty ? null : widget.value;
    } else {
      committed = _clamp(parsed);
    }

    if (committed != widget.value) {
      widget.onChanged(committed);
    }

    _controller.text = NumberField.format(committed, widget.decimals);
  }

  void _stepBy(int direction) {
    final current = _parse(_controller.text) ?? widget.value ?? widget.min ?? 0;
    var next = current + widget.step * direction;
    if (widget.decimals > 0) {
      final factor = List.filled(widget.decimals, 10).fold<int>(1, (value, element) => value * element);
      next = (next * factor).round() / factor;
    }

    next = _clamp(next);
    _controller.text = NumberField.format(next, widget.decimals);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final allowNegative = widget.min == null || widget.min! < 0;
    final pattern = widget.decimals > 0
        ? (allowNegative ? RegExp(r'^-?\d*\.?\d*$') : RegExp(r'^\d*\.?\d*$'))
        : (allowNegative ? RegExp(r'^-?\d*$') : RegExp(r'^\d*$'));
    final steppers = widget.showSteppers && widget.enabled
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StepButton(icon: Icons.remove, onPressed: () => _stepBy(-1)),
              _StepButton(icon: Icons.add, onPressed: () => _stepBy(1)),
              const SizedBox(width: 4),
            ],
          )
        : null;

    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      enabled: widget.enabled,
      keyboardType: TextInputType.numberWithOptions(decimal: widget.decimals > 0, signed: allowNegative),
      inputFormatters: [
        TextInputFormatter.withFunction((oldValue, newValue) => pattern.hasMatch(newValue.text) ? newValue : oldValue),
      ],
      onChanged: _onTextChanged,
      onSubmitted: (_) => _focusNode.unfocus(),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        suffixText: widget.suffixText,
        prefixIcon: widget.prefixIcon,
        suffixIcon: steppers,
        suffixIconConstraints: const BoxConstraints(minHeight: 36),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        color: context.colors.onSurfaceVariant,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    );
  }
}
