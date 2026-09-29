import 'package:flutter/material.dart';

import '../theme.dart';

/// A titled Material 3 card used for settings groups. Optionally collapsible, showing [summary]
/// while collapsed (used on phones to keep long forms short).
class SectionCard extends StatefulWidget {
  const SectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.collapsible = false,
    this.initiallyExpanded = true,
    this.summary,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 20),
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final bool collapsible;
  final bool initiallyExpanded;
  final String? summary;
  final EdgeInsets padding;

  @override
  State<SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<SectionCard> {
  late bool _expanded = widget.initiallyExpanded || !widget.collapsible;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: colors.secondaryContainer, borderRadius: BorderRadius.circular(12)),
          child: Icon(widget.icon, size: 20, color: colors.onSecondaryContainer),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, style: context.text.titleMedium),
              if (!_expanded && widget.summary != null)
                Text(
                  widget.summary!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                )
              else if (widget.subtitle != null)
                Text(widget.subtitle!, style: context.text.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
            ],
          ),
        ),
        ?widget.trailing,
        if (widget.collapsible)
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 200),
            child: Icon(Icons.expand_more, color: colors.onSurfaceVariant),
          ),
      ],
    );

    return Card(
      child: Padding(
        padding: widget.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.collapsible)
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _expanded = !_expanded),
                child: header,
              )
            else
              header,
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? Padding(padding: const EdgeInsets.only(top: 18), child: widget.child)
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small label above a form control.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.child, this.helper});

  final String text;
  final String? helper;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(text, style: context.text.labelMedium?.copyWith(color: context.colors.onSurfaceVariant)),
        ),
        ?child,
        if (helper != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: Text(helper!, style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant)),
          ),
      ],
    );
  }
}
