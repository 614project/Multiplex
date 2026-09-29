import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/image_timestamps.dart';
import '../../state/app_state.dart';
import '../../state/project_session.dart';
import '../actions.dart';
import '../common/server_status.dart';
import '../layout.dart';
import '../settings/app_settings_page.dart';
import '../theme.dart';
import '../workspace/cells_board.dart';
import '../workspace/generation_controls.dart';
import '../workspace/project_settings_view.dart';
import '../workspace/queue_view.dart';

/// Desktop and tablet layout: a project pane on the left (like the WinUI NavigationView of
/// WebuiMultiflex) and the tabbed project workspace on the right.
class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final session = app.selected;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            const ProjectPane(),
            Expanded(
              child: session == null
                  ? const Center(child: CircularProgressIndicator())
                  : ProjectWorkspace(session: session),
            ),
          ],
        ),
      ),
    );
  }
}

class ProjectPane extends StatelessWidget {
  const ProjectPane({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final expanded = app.preferences.projectsPaneExpanded;
    final colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: expanded ? 288 : 80,
      child: Material(
        color: colors.surfaceContainer,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: expanded ? 'Collapse' : 'Expand',
                    onPressed: () => app.updatePreferences((prefs) => prefs.projectsPaneExpanded = !expanded),
                    icon: const Icon(Icons.menu),
                  ),
                  if (expanded) ...[
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text('Multiplex', style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                      tooltip: 'Import projects',
                      onPressed: app.isBusy ? null : () => ProjectActions.import(context),
                      icon: const Icon(Icons.file_download_outlined),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: expanded ? 16 : 12, vertical: 8),
              child: expanded
                  ? FilledButton.tonalIcon(
                      onPressed: app.isBusy ? null : app.createProject,
                      icon: const Icon(Icons.add),
                      label: const Text('New project'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    )
                  : FloatingActionButton(
                      elevation: 0,
                      tooltip: 'New project',
                      onPressed: app.isBusy ? null : app.createProject,
                      child: const Icon(Icons.add),
                    ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 12, 16, 4),
                child: Text(
                  'PROJECTS',
                  style: context.text.labelSmall?.copyWith(color: colors.onSurfaceVariant, letterSpacing: 1.2),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                children: [
                  for (final project in app.projects)
                    _ProjectTile(session: project, selected: identical(project, app.selected), expanded: expanded),
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: expanded
                  ? ListTile(
                      leading: const Icon(Icons.settings_outlined),
                      title: const Text('Settings'),
                      onTap: () => openAppSettings(context),
                    )
                  : IconButton(
                      tooltip: 'Settings',
                      onPressed: () => openAppSettings(context),
                      icon: const Icon(Icons.settings_outlined),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ProjectMenu { rename, clone, export, openFolder, remove }

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({required this.session, required this.selected, required this.expanded});

  final ProjectSession session;
  final bool selected;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.generation]),
      builder: (context, _) {
        final colors = context.colors;
        final generation = session.generation;
        final working = generation.hasWork;
        final avatar = SizedBox.square(
          dimension: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: selected ? colors.primary : colors.surfaceContainerHighest,
                foregroundColor: selected ? colors.onPrimary : colors.onSurfaceVariant,
                child: Text(session.name.trim().isEmpty ? '?' : session.name.trim()[0].toUpperCase()),
              ),
              if (working)
                SizedBox.square(
                  dimension: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    value: generation.current?.fraction.clamp(0.02, 1.0),
                  ),
                ),
            ],
          ),
        );

        if (!expanded) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Tooltip(
              message: session.name,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => app.select(session),
                child: Padding(padding: const EdgeInsets.all(8), child: avatar),
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: ListTile(
            selected: selected,
            selectedTileColor: colors.secondaryContainer,
            selectedColor: colors.onSecondaryContainer,
            contentPadding: const EdgeInsets.only(left: 8, right: 0),
            leading: avatar,
            title: Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              working ? generation.summary : ImageTimestamps.formatShort(session.metadata.updatedAt),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => app.select(session),
            trailing: PopupMenuButton<_ProjectMenu>(
              tooltip: 'Project actions',
              itemBuilder: (_) => [
                const PopupMenuItem(value: _ProjectMenu.rename, child: Text('Rename')),
                const PopupMenuItem(value: _ProjectMenu.clone, child: Text('Clone')),
                const PopupMenuItem(value: _ProjectMenu.export, child: Text('Export')),
                if (PlatformInfo.canOpenFolders)
                  const PopupMenuItem(value: _ProjectMenu.openFolder, child: Text('Open folder')),
                const PopupMenuDivider(),
                PopupMenuItem(value: _ProjectMenu.remove, enabled: !working, child: const Text('Remove')),
              ],
              onSelected: (action) => switch (action) {
                _ProjectMenu.rename => ProjectActions.rename(context, session),
                _ProjectMenu.clone => ProjectActions.clone(context, session),
                _ProjectMenu.export => ProjectActions.export(context, session),
                _ProjectMenu.openFolder => ProjectActions.openFolder(context, session.projectFolder),
                _ProjectMenu.remove => ProjectActions.remove(context, session),
              },
            ),
          ),
        );
      },
    );
  }
}

/// Header with the generation controls, then Cells / Settings / Queue tabs.
class ProjectWorkspace extends StatefulWidget {
  const ProjectWorkspace({super.key, required this.session});

  final ProjectSession session;

  @override
  State<ProjectWorkspace> createState() => _ProjectWorkspaceState();
}

class _ProjectWorkspaceState extends State<ProjectWorkspace> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () => session.generate(),
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => session.generate(),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => ProjectActions.saveNow(context, session),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => ProjectActions.saveNow(context, session),
      },
      child: Focus(
        autofocus: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _WorkspaceHeader(session: session),
            ListenableBuilder(
              listenable: Listenable.merge([session, session.generation]),
              builder: (context, _) => TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tabs: [
                  Tab(icon: const Icon(Icons.grid_view), text: 'Cells (${session.cells.length})'),
                  const Tab(icon: Icon(Icons.tune), text: 'Settings'),
                  Tab(
                    icon: const Icon(Icons.queue_outlined),
                    text: session.generation.jobCount > 0 ? 'Queue (${session.generation.jobCount})' : 'Queue',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  CellsBoard(key: ValueKey('cells-${session.id}'), session: session),
                  ProjectSettingsView(key: ValueKey('settings-${session.id}'), session: session),
                  QueueView(key: ValueKey('queue-${session.id}'), session: session),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _WorkspaceMenu { save, rename, clone, export, collect, openFolder, remove }

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({required this.session});

  final ProjectSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.generation]),
      builder: (context, _) {
        final generation = session.generation;
        final colors = context.colors;
        final job = generation.current;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => ProjectActions.rename(context, session),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Text(
                              session.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ServerStatusChip(session: session),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The stop button and the variable-width Generate label sit on the left so the
                      // repeat stepper and the menu keep their position while a job starts and stops.
                      if (generation.isGenerating) ...[InterruptButton(session: session), const SizedBox(width: 8)],
                      FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                        onPressed: session.canGenerate ? () => session.generate() : null,
                        icon: const Icon(Icons.auto_awesome),
                        label: Text(generateButtonLabel(session)),
                      ),
                      const SizedBox(width: 10),
                      RepeatStepper(session: session),
                      const SizedBox(width: 4),
                      PopupMenuButton<_WorkspaceMenu>(
                        tooltip: 'Project actions',
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: _WorkspaceMenu.save,
                            child: ListTile(
                              leading: Icon(Icons.save_outlined),
                              title: Text('Save'),
                              trailing: Text('Ctrl+S'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: _WorkspaceMenu.rename,
                            child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Rename')),
                          ),
                          const PopupMenuItem(
                            value: _WorkspaceMenu.clone,
                            child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Clone')),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: _WorkspaceMenu.export,
                            child: ListTile(leading: Icon(Icons.upload_file_outlined), title: Text('Export JSON')),
                          ),
                          const PopupMenuItem(
                            value: _WorkspaceMenu.collect,
                            child: ListTile(leading: Icon(Icons.collections_outlined), title: Text('Collect images')),
                          ),
                          if (PlatformInfo.canOpenFolders)
                            const PopupMenuItem(
                              value: _WorkspaceMenu.openFolder,
                              child: ListTile(leading: Icon(Icons.folder_open_outlined), title: Text('Open folder')),
                            ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: _WorkspaceMenu.remove,
                            enabled: !generation.hasWork,
                            child: const ListTile(leading: Icon(Icons.delete_outline), title: Text('Remove project')),
                          ),
                        ],
                        onSelected: (action) => switch (action) {
                          _WorkspaceMenu.save => ProjectActions.saveNow(context, session),
                          _WorkspaceMenu.rename => ProjectActions.rename(context, session),
                          _WorkspaceMenu.clone => ProjectActions.clone(context, session),
                          _WorkspaceMenu.export => ProjectActions.export(context, session),
                          _WorkspaceMenu.collect => ProjectActions.collect(context, session),
                          _WorkspaceMenu.openFolder => ProjectActions.openFolder(context, session.projectFolder),
                          _WorkspaceMenu.remove => ProjectActions.remove(context, session),
                        },
                      ),
                    ],
                  ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: generation.hasWork
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Row(
                          children: [
                            Icon(Icons.bolt, size: 18, color: colors.primary),
                            const SizedBox(width: 8),
                            Flexible(
                              flex: 2,
                              child: Text(
                                generation.summary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.text.bodyMedium,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 3,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(value: job?.fraction, minHeight: 6),
                              ),
                            ),
                            if (job != null) ...[
                              const SizedBox(width: 12),
                              Text(job.progressText, style: context.text.labelLarge),
                            ],
                            if (generation.pending.isNotEmpty) ...[
                              const SizedBox(width: 12),
                              Text(
                                '+${generation.pending.length} queued',
                                style: context.text.labelMedium?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        );
      },
    );
  }
}
