import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/url_tools.dart';
import '../../state/app_state.dart';
import '../../state/project_session.dart';
import '../actions.dart';
import '../common/server_status.dart';
import '../layout.dart';
import '../settings/app_settings_page.dart';
import '../theme.dart';
import '../workspace/project_settings_view.dart';
import '../workspace/queue_view.dart';
import 'generation_dock.dart';
import 'mobile_cells_view.dart';
import 'project_switcher_sheet.dart';

/// Touch-first layout for phones and narrow windows: a project switcher in the app bar, three
/// destinations (Cells, Setup, Queue) and the floating generation dock above the navigation bar.
class MobileShell extends StatefulWidget {
  const MobileShell({super.key});

  @override
  State<MobileShell> createState() => _MobileShellState();
}

enum _Destination { cells, setup, queue }

class _MobileShellState extends State<MobileShell> {
  _Destination _destination = _Destination.cells;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final session = app.selected;
    if (session == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return ListenableBuilder(
      listenable: Listenable.merge([session, session.generation]),
      builder: (context, _) {
        final selecting = session.selectedCount > 0 && _destination == _Destination.cells;
        final useRail = WindowClass.of(context) == WindowClass.medium;
        final queueCount = session.generation.jobCount;
        final destinations = <(IconData, IconData, String, int)>[
          (Icons.grid_view_outlined, Icons.grid_view_rounded, 'Cells', 0),
          (Icons.tune_outlined, Icons.tune, 'Setup', 0),
          (Icons.queue_outlined, Icons.queue, 'Queue', queueCount),
        ];

        Widget icon(IconData data, int count) => count > 0 ? Badge.count(count: count, child: Icon(data)) : Icon(data);

        const dockSpace = 16.0;
        final body = switch (_destination) {
          _Destination.cells => MobileCellsView(
            key: ValueKey('cells-${session.id}'),
            session: session,
            selecting: selecting,
            bottomPadding: dockSpace,
          ),
          _Destination.setup => ProjectSettingsView(
            key: ValueKey('setup-${session.id}'),
            session: session,
            compact: true,
            bottomPadding: dockSpace,
          ),
          _Destination.queue => QueueView(
            key: ValueKey('queue-${session.id}'),
            session: session,
            compact: true,
            bottomPadding: dockSpace,
          ),
        };

        final dock = GenerationDock(
          session: session,
          onOpenQueue: () => setState(() => _destination = _Destination.queue),
        );

        return PopScope(
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && selecting) {
              session.setAllSelected(false);
            }
          },
          child: Scaffold(
            appBar: selecting ? _selectionAppBar(context, session) : _projectAppBar(context, session),
            body: Row(
              children: [
                if (useRail)
                  NavigationRail(
                    selectedIndex: _destination.index,
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -0.8,
                    onDestinationSelected: (index) => setState(() => _destination = _Destination.values[index]),
                    destinations: [
                      for (final (outlined, filled, label, count) in destinations)
                        NavigationRailDestination(
                          icon: icon(outlined, count),
                          selectedIcon: icon(filled, count),
                          label: Text(label),
                        ),
                    ],
                  ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(animation),
                        child: child,
                      ),
                    ),
                    child: body,
                  ),
                ),
              ],
            ),
            bottomNavigationBar: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                dock,
                if (!useRail)
                  NavigationBar(
                    selectedIndex: _destination.index,
                    onDestinationSelected: (index) => setState(() => _destination = _Destination.values[index]),
                    destinations: [
                      for (final (outlined, filled, label, count) in destinations)
                        NavigationDestination(
                          icon: icon(outlined, count),
                          selectedIcon: icon(filled, count),
                          label: label,
                        ),
                    ],
                  )
                else
                  SizedBox(height: MediaQuery.paddingOf(context).bottom),
              ],
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _projectAppBar(BuildContext context, ProjectSession session) {
    final colors = context.colors;
    return AppBar(
      titleSpacing: 8,
      title: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showProjectSwitcher(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  const Icon(Icons.expand_more),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusDot(status: session.serverStatus, size: 8),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '${session.settings.platform.label} · ${EndpointResolver.describe(session.resolvedApiBaseUrl)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Server connection',
          onPressed: () => showConnectionSheet(context, session),
          icon: const Icon(Icons.settings_ethernet),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'rename',
              child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Rename project')),
            ),
            const PopupMenuItem(
              value: 'clone',
              child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Clone project')),
            ),
            const PopupMenuItem(
              value: 'export',
              child: ListTile(leading: Icon(Icons.ios_share), title: Text('Export JSON')),
            ),
            const PopupMenuItem(
              value: 'collect',
              child: ListTile(leading: Icon(Icons.collections_outlined), title: Text('Collect images')),
            ),
            PopupMenuItem(
              value: 'remove',
              enabled: !session.generation.hasWork,
              child: const ListTile(leading: Icon(Icons.delete_outline), title: Text('Remove project')),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'settings',
              child: ListTile(leading: Icon(Icons.settings_outlined), title: Text('Settings')),
            ),
          ],
          onSelected: (value) => switch (value) {
            'rename' => ProjectActions.rename(context, session),
            'clone' => ProjectActions.clone(context, session),
            'export' => ProjectActions.export(context, session),
            'collect' => ProjectActions.collect(context, session),
            'remove' => ProjectActions.remove(context, session),
            _ => openAppSettings(context),
          },
        ),
      ],
    );
  }

  PreferredSizeWidget _selectionAppBar(BuildContext context, ProjectSession session) {
    final colors = context.colors;
    final selected = session.cells.where((cell) => cell.isSelected).toList();
    return AppBar(
      backgroundColor: colors.secondaryContainer,
      foregroundColor: colors.onSecondaryContainer,
      leading: IconButton(
        tooltip: 'Clear selection',
        onPressed: () => session.setAllSelected(false),
        icon: const Icon(Icons.close),
      ),
      title: Text('${selected.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Select all',
          onPressed: () => session.setAllSelected(true),
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: 'Remove selected cells',
          onPressed: () => ProjectActions.removeCells(context, session, selected),
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }
}
