import 'package:flutter/material.dart';

import '../../core/image_timestamps.dart';
import '../../generation/generation_context.dart';
import '../../state/project_session.dart';
import '../common/cell_image.dart';
import '../common/dialogs.dart';
import '../theme.dart';

/// The project's generation queue: the running job pinned on top, waiting jobs below (drag to
/// reorder, remove individually or all at once).
class QueueView extends StatelessWidget {
  const QueueView({super.key, required this.session, this.compact = false, this.bottomPadding = 24});

  final ProjectSession session;
  final bool compact;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final generation = session.generation;
    return ListenableBuilder(
      listenable: generation,
      builder: (context, _) {
        if (!generation.hasWork) {
          return const EmptyState(
            icon: Icons.queue_outlined,
            title: 'No queued jobs',
            message: 'Generate or regenerate cells to add work here. Jobs run one after another in this project.',
          );
        }

        final current = generation.current;
        final pending = generation.pending;
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 12, compact ? 12 : 20, 0),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (current != null) ...[
                          _SectionLabel(text: 'Running'),
                          _CurrentJobCard(session: session, job: current),
                          const SizedBox(height: 20),
                        ],
                        if (pending.isNotEmpty)
                          Row(
                            children: [
                              Expanded(child: _SectionLabel(text: 'Waiting · ${pending.length}')),
                              TextButton.icon(
                                onPressed: session.clearQueuedJobs,
                                icon: const Icon(Icons.clear_all),
                                label: const Text('Clear'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 0, compact ? 12 : 20, bottomPadding),
              sliver: SliverReorderableList(
                itemCount: pending.length,
                onReorderItem: session.moveQueuedJob,
                itemBuilder: (context, index) {
                  final job = pending[index];
                  final card = _QueuedJobCard(
                    job: job,
                    index: index,
                    compact: compact,
                    onRemove: () => session.removeQueuedJob(job),
                  );
                  return Center(
                    key: ObjectKey(job),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: compact
                            ? Dismissible(
                                key: ObjectKey(job),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 24),
                                  decoration: BoxDecoration(
                                    color: context.colors.errorContainer,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Icon(Icons.delete_outline, color: context.colors.onErrorContainer),
                                ),
                                onDismissed: (_) => session.removeQueuedJob(job),
                                child: card,
                              )
                            : card,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: context.text.labelMedium?.copyWith(color: context.colors.primary, letterSpacing: 1.1),
      ),
    );
  }
}

class _CurrentJobCard extends StatelessWidget {
  const _CurrentJobCard({required this.session, required this.job});

  final ProjectSession session;
  final GenerationJob job;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final generation = session.generation;
    final preview = generation.preview;
    return Card(
      color: colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox.square(
                dimension: 72,
                child: preview != null
                    ? MemoryPreview(bytes: preview)
                    : ColoredBox(
                        color: colors.surfaceContainerHighest,
                        child: const Center(
                          child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 3)),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(job.title, style: context.text.titleMedium?.copyWith(color: colors.onSecondaryContainer)),
                  Text(job.description, style: context.text.bodySmall?.copyWith(color: colors.onSecondaryContainer)),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(value: job.fraction, minHeight: 8),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    job.status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodyMedium?.copyWith(color: colors.onSecondaryContainer),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              children: [
                Text(job.progressText, style: context.text.titleLarge?.copyWith(color: colors.onSecondaryContainer)),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: generation.forceInterruptRequested ? null : session.interrupt,
                  icon: Icon(generation.stopAfterCurrentImageRequested ? Icons.stop_circle : Icons.stop),
                  label: Text(generation.stopAfterCurrentImageRequested ? 'Force stop' : 'Stop'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QueuedJobCard extends StatelessWidget {
  const _QueuedJobCard({required this.job, required this.index, required this.compact, required this.onRemove});

  final GenerationJob job;
  final int index;
  final bool compact;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        leading: ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.drag_indicator, color: colors.onSurfaceVariant),
          ),
        ),
        title: Text(job.title),
        subtitle: Text('${job.description}\n${job.status} · ${ImageTimestamps.format(job.createdAt)}'),
        isThreeLine: true,
        trailing: compact
            ? null
            : IconButton(tooltip: 'Remove from queue', onPressed: onRemove, icon: const Icon(Icons.close)),
      ),
    );
  }
}
