import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_preferences.dart';
import '../../state/app_state.dart';
import '../../state/cell_model.dart';
import '../../state/project_session.dart';
import '../actions.dart';
import '../cell_detail/cell_detail_page.dart';
import '../common/cell_image.dart';
import '../common/dialogs.dart';
import '../common/prompt_field.dart';
import '../theme.dart';
import 'cell_menu.dart';

/// Desktop cell editor: a reorderable list (image beside the prompt) or a grid of large icons.
class CellsBoard extends StatelessWidget {
  const CellsBoard({super.key, required this.session});

  final ProjectSession session;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final prefs = app.preferences;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final cells = session.cells;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BoardHeader(session: session, layout: prefs.cellLayout),
            Expanded(
              child: cells.isEmpty
                  ? EmptyState(
                      icon: Icons.grid_view,
                      title: 'No cells yet',
                      message: 'Cells hold the prompts that are generated in a batch.',
                      action: FilledButton.icon(
                        onPressed: session.addCell,
                        icon: const Icon(Icons.add),
                        label: const Text('Add cell'),
                      ),
                    )
                  : prefs.cellLayout == CellLayout.list
                  ? ReorderableListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                      buildDefaultDragHandles: false,
                      itemCount: cells.length,
                      onReorderItem: session.moveCell,
                      itemBuilder: (context, index) => Padding(
                        key: ValueKey(cells[index].id),
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ListCellCard(
                          session: session,
                          cell: cells[index],
                          index: index,
                          minHeight: prefs.listCellHeight.toDouble(),
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (var index = 0; index < cells.length; index++)
                            GridCellCard(
                              key: ValueKey(cells[index].id),
                              session: session,
                              cell: cells[index],
                              index: index,
                              width: prefs.gridCellWidth.toDouble(),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _BoardHeader extends StatelessWidget {
  const _BoardHeader({required this.session, required this.layout});

  final ProjectSession session;
  final CellLayout layout;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final selected = session.cells.where((cell) => cell.isSelected).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                tristate: true,
                value: session.selectAllState,
                onChanged: (_) => session.setAllSelected(session.selectAllState != true),
              ),
              Text(session.cellSelectionSummary, style: context.text.titleSmall),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                onPressed: session.addCell,
                icon: const Icon(Icons.add),
                label: const Text('Add cell'),
              ),
              if (selected.isNotEmpty) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => ProjectActions.removeCells(context, session, selected),
                  icon: const Icon(Icons.delete_outline),
                  label: Text('Remove ${selected.length}'),
                ),
              ],
            ],
          ),
          SegmentedButton<CellLayout>(
            segments: const [
              ButtonSegment(value: CellLayout.list, icon: Icon(Icons.view_agenda_outlined), label: Text('List')),
              ButtonSegment(value: CellLayout.grid, icon: Icon(Icons.grid_view), label: Text('Large icons')),
            ],
            selected: {layout},
            onSelectionChanged: (selection) => app.updatePreferences((prefs) => prefs.cellLayout = selection.first),
          ),
        ],
      ),
    );
  }
}

/// Image preview of a cell with its busy/live-preview overlay. Tap opens the image history.
class CellPreview extends StatelessWidget {
  const CellPreview({
    super.key,
    required this.session,
    required this.cell,
    this.fit = BoxFit.contain,
    this.decodeWidth,
  });

  final ProjectSession session;
  final CellModel cell;
  final BoxFit fit;
  final double? decodeWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final path = cell.displayImagePath;
    final preview = cell.livePreview;
    return Material(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: path == null ? () => session.regenerate(cell) : () => openCellDetail(context, session, cell),
        onSecondaryTapUp: (details) => showCellContextMenu(context, session, cell, details.globalPosition),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (path != null)
              Hero(
                tag: 'cell-image-${cell.id}',
                child: FileThumbnail(path: path, fit: fit, decodeWidth: decodeWidth),
              )
            else
              const ImagePlaceholder(icon: Icons.auto_awesome_outlined, label: 'Click to generate'),
            if (cell.isBusy && preview != null)
              Positioned.fill(
                child: MemoryPreview(bytes: preview, fit: fit),
              ),
            if (cell.isBusy)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: colors.surface.withValues(alpha: 0.75), shape: BoxShape.circle),
                  child: SizedBox.square(
                    dimension: 28,
                    child: CircularProgressIndicator(value: cell.liveProgress, strokeWidth: 3),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CellHeader extends StatelessWidget {
  const _CellHeader({required this.session, required this.cell, this.dragHandle});

  final ProjectSession session;
  final CellModel cell;
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        ?dragHandle,
        Checkbox(value: cell.isSelected, onChanged: (value) => cell.isSelected = value ?? false),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => ProjectActions.renameCell(context, cell),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Text(
                cell.displayName,
                style: context.text.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        for (final label in cell.overrideLabels)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Tooltip(
              message: 'Cell override',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: colors.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
                child: Text(label, style: context.text.labelSmall?.copyWith(color: colors.onTertiaryContainer)),
              ),
            ),
          ),
        IconButton(
          tooltip: 'Regenerate this cell',
          onPressed: () => session.regenerate(cell),
          icon: const Icon(Icons.refresh),
        ),
        CellMenuButton(session: session, cell: cell),
      ],
    );
  }
}

class ListCellCard extends StatelessWidget {
  const ListCellCard({
    super.key,
    required this.session,
    required this.cell,
    required this.index,
    required this.minHeight,
  });

  final ProjectSession session;
  final CellModel cell;
  final int index;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: cell,
      builder: (context, _) => _SelectableCard(
        selected: cell.isSelected,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 220,
                    child: CellPreview(session: session, cell: cell, decodeWidth: 220),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _CellHeader(
                          session: session,
                          cell: cell,
                          dragHandle: ReorderableDragStartListener(
                            index: index,
                            child: const MouseRegion(
                              cursor: SystemMouseCursors.grab,
                              child: Padding(padding: EdgeInsets.all(4), child: Icon(Icons.drag_indicator, size: 20)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        PromptField(
                          hint: 'Cell prompt',
                          value: cell.prompt,
                          minLines: 4,
                          maxLines: 12,
                          onChanged: (value) => cell.prompt = value,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GridCellCard extends StatelessWidget {
  const GridCellCard({super.key, required this.session, required this.cell, required this.index, required this.width});

  final ProjectSession session;
  final CellModel cell;
  final int index;
  final double width;

  @override
  Widget build(BuildContext context) {
    return DragTarget<CellModel>(
      onWillAcceptWithDetails: (details) => details.data != cell,
      onAcceptWithDetails: (details) {
        final from = session.cells.indexOf(details.data);
        if (from >= 0) {
          session.moveCell(from, index);
        }
      },
      builder: (context, candidates, _) => ListenableBuilder(
        listenable: cell,
        builder: (context, _) {
          final card = _SelectableCard(
            selected: cell.isSelected,
            highlighted: candidates.isNotEmpty,
            child: SizedBox(
              width: width,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _CellHeader(
                      session: session,
                      cell: cell,
                      dragHandle: Draggable<CellModel>(
                        data: cell,
                        feedback: Material(
                          elevation: 8,
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Text(cell.displayName),
                          ),
                        ),
                        child: const MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Padding(padding: EdgeInsets.all(4), child: Icon(Icons.drag_indicator, size: 20)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    PromptField(
                      hint: 'Cell prompt',
                      value: cell.prompt,
                      minLines: 2,
                      maxLines: 8,
                      onChanged: (value) => cell.prompt = value,
                    ),
                    const SizedBox(height: 10),
                    AspectRatio(
                      aspectRatio: session.settings.width / session.settings.height,
                      child: CellPreview(session: session, cell: cell, decodeWidth: width),
                    ),
                  ],
                ),
              ),
            ),
          );
          return card;
        },
      ),
    );
  }
}

class _SelectableCard extends StatelessWidget {
  const _SelectableCard({required this.selected, required this.child, this.highlighted = false});

  final bool selected;
  final bool highlighted;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        color: selected ? colors.secondaryContainer.withValues(alpha: 0.55) : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: highlighted
              ? colors.primary
              : selected
              ? colors.secondary
              : colors.outlineVariant.withValues(alpha: 0.6),
          width: highlighted || selected ? 2 : 1,
        ),
      ),
      child: child,
    );
  }
}
