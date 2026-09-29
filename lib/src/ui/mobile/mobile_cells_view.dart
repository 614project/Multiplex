import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/url_tools.dart';
import '../../state/app_state.dart';
import '../../state/cell_model.dart';
import '../../state/project_session.dart';
import '../cell_detail/cell_detail_page.dart';
import '../common/cell_image.dart';
import '../common/server_status.dart';
import '../theme.dart';
import 'cell_editor_sheet.dart';

/// Phone gallery of cells. Tap a card to see its images (or edit it when it has none), long-press to
/// start selecting, and use the pencil to edit the prompt.
class MobileCellsView extends StatelessWidget {
  const MobileCellsView({super.key, required this.session, required this.selecting, required this.bottomPadding});

  final ProjectSession session;
  final bool selecting;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final columns = app.preferences.mobileCellColumns;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final cells = session.cells;
        return RefreshIndicator(
          onRefresh: session.refreshServer,
          child: CustomScrollView(
            slivers: [
              if (session.serverStatus == ServerStatus.offline)
                SliverToBoxAdapter(child: _ConnectionBanner(session: session)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          session.cellSelectionSummary,
                          style: context.text.titleSmall?.copyWith(color: context.colors.onSurfaceVariant),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Gallery columns',
                        onPressed: () =>
                            app.updatePreferences((prefs) => prefs.mobileCellColumns = prefs.mobileCellColumns % 3 + 1),
                        icon: Icon(switch (columns) {
                          1 => Icons.view_agenda_outlined,
                          2 => Icons.grid_view,
                          _ => Icons.apps,
                        }),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(12, 4, 12, bottomPadding),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: columns == 1 ? 1.1 : 0.72,
                  ),
                  itemCount: cells.length + 1,
                  itemBuilder: (context, index) => index == cells.length
                      ? _AddCellTile(
                          onTap: () {
                            final cell = session.addCell();
                            showCellEditor(context, session, cell, focusPrompt: true);
                          },
                        )
                      : MobileCellTile(session: session, cell: cells[index], selecting: selecting),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class MobileCellTile extends StatelessWidget {
  const MobileCellTile({super.key, required this.session, required this.cell, required this.selecting});

  final ProjectSession session;
  final CellModel cell;
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: cell,
      builder: (context, _) {
        final colors = context.colors;
        final path = cell.displayImagePath;
        final preview = cell.livePreview;
        final selected = cell.isSelected;
        return AnimatedScale(
          duration: const Duration(milliseconds: 160),
          scale: selecting && selected ? 0.94 : 1,
          child: Material(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                if (selecting) {
                  cell.isSelected = !selected;
                } else if (path != null) {
                  openCellDetail(context, session, cell);
                } else {
                  showCellEditor(context, session, cell, focusPrompt: true);
                }
              },
              onLongPress: () => cell.isSelected = !selected,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (path != null)
                    Hero(
                      tag: 'cell-image-${cell.id}',
                      child: FileThumbnail(path: path, decodeWidth: 240),
                    )
                  else
                    _PromptPlaceholder(cell: cell),
                  if (cell.isBusy && preview != null) MemoryPreview(bytes: preview),
                  // Legibility gradient for the caption.
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 90,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xCC000000), Color(0x00000000)],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 12,
                    right: 44,
                    bottom: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          cell.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.titleSmall?.copyWith(color: Colors.white),
                        ),
                        if (cell.overrideLabels.isNotEmpty)
                          Text(
                            cell.overrideLabels.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.labelSmall?.copyWith(color: Colors.white70),
                          ),
                      ],
                    ),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 2,
                    child: IconButton(
                      tooltip: 'Edit cell',
                      color: Colors.white,
                      onPressed: () => showCellEditor(context, session, cell),
                      icon: const Icon(Icons.edit_outlined, size: 20),
                    ),
                  ),
                  if (cell.isBusy)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: colors.surface.withValues(alpha: 0.85),
                          shape: BoxShape.circle,
                        ),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(value: cell.liveProgress, strokeWidth: 2.5),
                        ),
                      ),
                    ),
                  if (selecting || selected)
                    Positioned(
                      top: 10,
                      left: 10,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected ? colors.primary : Colors.black26,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: selected ? Icon(Icons.check, size: 16, color: colors.onPrimary) : null,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PromptPlaceholder extends StatelessWidget {
  const _PromptPlaceholder({required this.cell});

  final CellModel cell;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final prompt = cell.prompt.trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.primaryContainer, colors.tertiaryContainer],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 56),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome_outlined, color: colors.onPrimaryContainer.withValues(alpha: 0.7)),
            const SizedBox(height: 10),
            Expanded(
              child: Text(
                prompt.isEmpty ? 'Tap to write a prompt' : prompt,
                overflow: TextOverflow.fade,
                style: context.text.bodyMedium?.copyWith(
                  color: colors.onPrimaryContainer.withValues(alpha: prompt.isEmpty ? 0.6 : 0.9),
                  fontStyle: prompt.isEmpty ? FontStyle.italic : FontStyle.normal,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddCellTile extends StatelessWidget {
  const _AddCellTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: colors.outlineVariant, width: 1.5),
      ),
      child: InkWell(
        customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: colors.secondaryContainer,
              child: Icon(Icons.add, color: colors.onSecondaryContainer),
            ),
            const SizedBox(height: 10),
            Text('New cell', style: context.text.titleSmall),
          ],
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.session});

  final ProjectSession session;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Card(
        color: colors.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.cloud_off, color: colors.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      "Can't reach ${EndpointResolver.describe(session.resolvedApiBaseUrl)}",
                      style: context.text.titleSmall?.copyWith(color: colors.onErrorContainer),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                session.serverMessage,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySmall?.copyWith(color: colors.onErrorContainer),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.onErrorContainer),
                  onPressed: () => showConnectionSheet(context, session),
                  icon: const Icon(Icons.settings_ethernet),
                  label: const Text('Set up connection'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
