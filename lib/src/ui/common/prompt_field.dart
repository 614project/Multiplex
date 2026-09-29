import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/autocomplete_service.dart';
import '../../state/app_state.dart';
import '../layout.dart';
import '../theme.dart';

enum SuggestionStyle { popup, chips }

/// Multi-line prompt editor with tag autocomplete.
///
/// Desktop shows a popup under the field (arrow keys to move, Tab to accept, Esc to dismiss).
/// Phones show a strip of suggestion chips under the field; accepting one also adds ", ".
class PromptField extends StatefulWidget {
  const PromptField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.hint,
    this.minLines = 3,
    this.maxLines = 10,
    this.enabled = true,
    this.style,
    this.autofocus = false,
    this.filled,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? label;
  final String? hint;
  final int minLines;
  final int? maxLines;
  final bool enabled;
  final SuggestionStyle? style;
  final bool autofocus;
  final bool? filled;

  @override
  State<PromptField> createState() => _PromptFieldState();
}

class _PromptFieldState extends State<PromptField> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);
  final FocusNode _focusNode = FocusNode();
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  List<String> _suggestions = const [];
  PromptFragment? _fragment;
  int _highlighted = 0;
  bool _dismissed = false;
  bool _suppressNext = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
    _controller.addListener(_onSelectionMaybeChanged);
  }

  @override
  void didUpdateWidget(PromptField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) {
      final selection = _controller.selection;
      final newSelection = selection.isValid && selection.end <= widget.value.length
          ? selection
          : TextSelection.collapsed(offset: widget.value.length);
      // Updating the controller notifies listeners during build; pre-record the new state so the
      // suggestion listener treats it as unchanged.
      _lastText = widget.value;
      _lastCaret = newSelection.isCollapsed ? newSelection.baseOffset : -1;
      _controller.value = TextEditingValue(text: widget.value, selection: newSelection);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _controller.removeListener(_onSelectionMaybeChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  SuggestionStyle _style(BuildContext context) =>
      widget.style ??
      (PlatformInfo.isMobile || WindowClass.of(context).usesMobileLayout
          ? SuggestionStyle.chips
          : SuggestionStyle.popup);

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) {
      _dismissed = false;
      _setSuggestions(const [], null);
    }
  }

  String _lastText = '';
  int _lastCaret = -1;

  void _onSelectionMaybeChanged() {
    final caret = _controller.selection.isCollapsed ? _controller.selection.baseOffset : -1;
    if (_controller.text == _lastText && caret == _lastCaret) {
      return;
    }

    final textChanged = _controller.text != _lastText;
    _lastText = _controller.text;
    _lastCaret = caret;
    if (_suppressNext) {
      _suppressNext = false;
      _setSuggestions(const [], null);
      return;
    }

    if (textChanged) {
      _dismissed = false;
    }

    _refreshSuggestions();
  }

  void _refreshSuggestions() {
    if (!_focusNode.hasFocus || _dismissed || !widget.enabled) {
      _setSuggestions(const [], null);
      return;
    }

    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _setSuggestions(const [], null);
      return;
    }

    final fragment = PromptFragment.at(_controller.text, selection.baseOffset);
    if (fragment == null) {
      _setSuggestions(const [], null);
      return;
    }

    final service = context.read<AppState>().autocomplete;
    final suggestions = service.suggestionsFor(fragment.text);
    // Hide the popup when the only suggestion is exactly what was typed.
    final exact =
        suggestions.length == 1 &&
        AutocompleteService.normalizeSearchKey(suggestions.first) ==
            AutocompleteService.normalizeSearchKey(fragment.text);
    _setSuggestions(exact ? const [] : suggestions, fragment);
  }

  void _setSuggestions(List<String> suggestions, PromptFragment? fragment) {
    final changed =
        suggestions.length != _suggestions.length ||
        !Iterable<int>.generate(suggestions.length).every((index) => suggestions[index] == _suggestions[index]);
    _fragment = fragment;
    if (changed) {
      _highlighted = 0;
    }

    _suggestions = suggestions;
    if (!mounted) {
      return;
    }

    if (_style(context) == SuggestionStyle.popup) {
      if (suggestions.isEmpty) {
        _portal.hide();
      } else {
        _portal.show();
      }
    }

    if (changed) {
      setState(() {});
    }
  }

  void _accept(String suggestion, {required bool appendSeparator}) {
    final fragment = _fragment;
    if (fragment == null) {
      return;
    }

    final (text, caret) = fragment.apply(_controller.text, suggestion, appendSeparator: appendSeparator);
    _suppressNext = true;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
    );
    widget.onChanged(text);
    _setSuggestions(const [], null);
    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_suggestions.isEmpty || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlighted = (_highlighted + 1) % _suggestions.length);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlighted = (_highlighted - 1 + _suggestions.length) % _suggestions.length);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.tab && event is KeyDownEvent) {
      _accept(_suggestions[_highlighted.clamp(0, _suggestions.length - 1)], appendSeparator: false);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape && event is KeyDownEvent) {
      _dismissed = true;
      _setSuggestions(const [], null);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final style = _style(context);
    final field = TextField(
      controller: _controller,
      focusNode: _focusNode,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.none,
      onChanged: widget.onChanged,
      style: context.text.bodyMedium?.copyWith(height: 1.4),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        filled: widget.filled,
        hintMaxLines: 3,
      ),
    );

    final keyed = Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: field);
    if (style == SuggestionStyle.chips) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          keyed,
          AnimatedSize(
            duration: const Duration(milliseconds: 160),
            alignment: Alignment.topCenter,
            child: _suggestions.isEmpty
                ? const SizedBox(width: double.infinity)
                : TextFieldTapRegion(
                    child: _SuggestionChips(
                      suggestions: _suggestions,
                      onSelected: (suggestion) => _accept(suggestion, appendSeparator: true),
                    ),
                  ),
          ),
        ],
      );
    }

    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => _SuggestionPopup(
          link: _link,
          suggestions: _suggestions,
          highlighted: _highlighted,
          fieldWidth: (this.context.findRenderObject() as RenderBox?)?.size.width ?? 320,
          onSelected: (suggestion) => _accept(suggestion, appendSeparator: false),
        ),
        child: keyed,
      ),
    );
  }
}

class _SuggestionPopup extends StatelessWidget {
  const _SuggestionPopup({
    required this.link,
    required this.suggestions,
    required this.highlighted,
    required this.fieldWidth,
    required this.onSelected,
  });

  final LayerLink link;
  final List<String> suggestions;
  final int highlighted;
  final double fieldWidth;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    final colors = context.colors;
    return Positioned(
      width: fieldWidth.clamp(220.0, 420.0),
      child: CompositedTransformFollower(
        link: link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        offset: const Offset(0, 4),
        child: TextFieldTapRegion(
          child: Material(
            elevation: 6,
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < suggestions.length; index++)
                  InkWell(
                    canRequestFocus: false,
                    onTap: () => onSelected(suggestions[index]),
                    child: Container(
                      color: index == highlighted ? colors.secondaryContainer : null,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.sell_outlined, size: 16, color: colors.onSurfaceVariant),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              suggestions[index].replaceAll('_', ' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.bodyMedium?.copyWith(
                                color: index == highlighted ? colors.onSecondaryContainer : colors.onSurface,
                              ),
                            ),
                          ),
                          if (index == highlighted)
                            Text('Tab', style: context.text.labelSmall?.copyWith(color: colors.onSurfaceVariant)),
                        ],
                      ),
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

class _SuggestionChips extends StatelessWidget {
  const _SuggestionChips({required this.suggestions, required this.onSelected});

  final List<String> suggestions;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.only(top: 8),
        scrollDirection: Axis.horizontal,
        itemCount: suggestions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) => ActionChip(
          avatar: const Icon(Icons.add, size: 16),
          label: Text(suggestions[index].replaceAll('_', ' ')),
          visualDensity: VisualDensity.compact,
          onPressed: () => onSelected(suggestions[index]),
        ),
      ),
    );
  }
}
