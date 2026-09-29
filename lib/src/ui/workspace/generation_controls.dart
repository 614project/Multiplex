import 'package:flutter/material.dart';

import '../../state/project_session.dart';
import '../theme.dart';

/// "×N" stepper for how many round-robin passes a Generate press queues.
class RepeatStepper extends StatelessWidget {
  const RepeatStepper({super.key, required this.session, this.dense = false});

  final ProjectSession session;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final count = session.generateRepeatCount;
    return Tooltip(
      message: 'Generate each target cell this many times, in round-robin order',
      child: Container(
        height: dense ? 40 : 44,
        decoration: BoxDecoration(color: colors.surfaceContainerHighest, borderRadius: BorderRadius.circular(22)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: count > 1 ? () => session.generateRepeatCount = count - 1 : null,
              icon: const Icon(Icons.remove, size: 18),
            ),
            SizedBox(
              width: 30,
              child: Text('×$count', textAlign: TextAlign.center, style: context.text.titleSmall),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: count < 99 ? () => session.generateRepeatCount = count + 1 : null,
              icon: const Icon(Icons.add, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

String generateButtonLabel(ProjectSession session) {
  final selected = session.selectedCount;
  final count = selected == 0 ? session.cells.length : selected;
  final noun = count == 1 ? 'cell' : 'cells';
  final images = count * session.generateRepeatCount;
  final suffix = session.generateRepeatCount > 1 ? ' · $images images' : '';
  return selected == 0 ? 'Generate $count $noun$suffix' : 'Generate $count selected$suffix';
}

/// Two-stage interrupt button: "Stop" (after the current image) then "Force stop".
class InterruptButton extends StatelessWidget {
  const InterruptButton({super.key, required this.session, this.iconOnly = false});

  final ProjectSession session;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final generation = session.generation;
    final soft = generation.stopAfterCurrentImageRequested;
    final label = generation.forceInterruptRequested ? 'Stopping…' : (soft ? 'Force stop' : 'Stop');
    final tooltip = soft
        ? 'Stop immediately and cancel the current image'
        : 'Stop after the image that is being generated';
    final onPressed = generation.isGenerating && !generation.forceInterruptRequested ? session.interrupt : null;
    if (iconOnly) {
      return IconButton.filledTonal(
        tooltip: tooltip,
        onPressed: onPressed,
        style: soft
            ? IconButton.styleFrom(
                backgroundColor: context.colors.errorContainer,
                foregroundColor: context.colors.onErrorContainer,
              )
            : null,
        icon: Icon(soft ? Icons.stop_circle : Icons.stop_rounded),
      );
    }

    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: soft ? OutlinedButton.styleFrom(foregroundColor: context.colors.error) : null,
        icon: Icon(soft ? Icons.stop_circle : Icons.stop_rounded),
        label: Text(label),
      ),
    );
  }
}
