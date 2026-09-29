import 'package:flutter/material.dart';

import '../../state/project_session.dart';
import '../common/cell_image.dart';
import '../theme.dart';
import '../workspace/generation_controls.dart';

/// The phone's floating generation control. Idle it is a big Generate button with a repeat stepper;
/// while a job runs it turns into a "now generating" mini player with the live preview, progress and a
/// two-stage stop button. Tapping the mini player opens the queue.
class GenerationDock extends StatelessWidget {
  const GenerationDock({super.key, required this.session, required this.onOpenQueue});

  final ProjectSession session;
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.generation]),
      builder: (context, _) {
        final colors = context.colors;
        final running = session.generation.current != null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Material(
            color: running ? colors.primaryContainer : colors.surfaceContainerHigh,
            elevation: 3,
            shadowColor: Colors.black.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(28),
            clipBehavior: Clip.antiAlias,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: running
                    ? _RunningDock(key: const ValueKey('running'), session: session, onOpenQueue: onOpenQueue)
                    : _IdleDock(key: const ValueKey('idle'), session: session, onOpenQueue: onOpenQueue),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _IdleDock extends StatelessWidget {
  const _IdleDock({super.key, required this.session, required this.onOpenQueue});

  final ProjectSession session;
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    final pending = session.generation.pending.length;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          RepeatStepper(session: session, dense: true),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: session.canGenerate ? () => session.generate() : null,
              icon: const Icon(Icons.auto_awesome),
              label: FittedBox(fit: BoxFit.scaleDown, child: Text(generateButtonLabel(session))),
            ),
          ),
          if (pending > 0) ...[
            const SizedBox(width: 8),
            Badge.count(
              count: pending,
              child: IconButton.filledTonal(onPressed: onOpenQueue, icon: const Icon(Icons.queue_outlined)),
            ),
          ],
        ],
      ),
    );
  }
}

class _RunningDock extends StatelessWidget {
  const _RunningDock({super.key, required this.session, required this.onOpenQueue});

  final ProjectSession session;
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final generation = session.generation;
    final job = generation.current!;
    final preview = generation.preview;
    final previewCell = generation.previewCellId == null ? null : session.cellById(generation.previewCellId!);
    final pending = generation.pending.length;
    return InkWell(
      onTap: onOpenQueue,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: SizedBox.square(
                    dimension: 52,
                    child: preview != null
                        ? MemoryPreview(bytes: preview)
                        : ColoredBox(
                            color: colors.surface.withValues(alpha: 0.5),
                            child: Center(
                              child: SizedBox.square(
                                dimension: 24,
                                child: CircularProgressIndicator(strokeWidth: 3, color: colors.onPrimaryContainer),
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        previewCell == null ? job.title : '${previewCell.displayName} · ${job.progressText}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.titleSmall?.copyWith(color: colors.onPrimaryContainer),
                      ),
                      Text(
                        job.status + (pending > 0 ? '  ·  +$pending queued' : ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodySmall?.copyWith(
                          color: colors.onPrimaryContainer.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Queue more',
                  onPressed: session.canGenerate ? () => session.generate() : null,
                  color: colors.onPrimaryContainer,
                  icon: const Icon(Icons.add_circle_outline),
                ),
                InterruptButton(session: session, iconOnly: true),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: job.fraction,
                minHeight: 4,
                backgroundColor: colors.onPrimaryContainer.withValues(alpha: 0.12),
                color: colors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
