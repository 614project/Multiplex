import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/image_timestamps.dart';
import '../../state/app_state.dart';
import '../../state/project_session.dart';
import '../actions.dart';
import '../theme.dart';

/// Switch between projects on phones (like switching accounts), create or import projects.
Future<void> showProjectSwitcher(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, scrollController) => _ProjectSwitcher(scrollController: scrollController),
    ),
  );
}

class _ProjectSwitcher extends StatelessWidget {
  const _ProjectSwitcher({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Row(
            children: [
              Expanded(child: Text('Projects', style: context.text.headlineSmall)),
              IconButton(
                tooltip: 'Import',
                onPressed: app.isBusy
                    ? null
                    : () async {
                        Navigator.pop(context);
                        await ProjectActions.import(context);
                      },
                icon: const Icon(Icons.file_download_outlined),
              ),
            ],
          ),
        ),
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: app.isBusy
              ? null
              : () async {
                  final navigator = Navigator.of(context);
                  await app.createProject();
                  navigator.pop();
                },
          icon: const Icon(Icons.add),
          label: const Text('New project'),
        ),
        const SizedBox(height: 12),
        for (final project in app.projects)
          _ProjectRow(
            session: project,
            selected: identical(project, app.selected),
            onTap: () {
              app.select(project);
              Navigator.pop(context);
            },
          ),
      ],
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({required this.session, required this.selected, required this.onTap});

  final ProjectSession session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.generation]),
      builder: (context, _) {
        final colors = context.colors;
        final generation = session.generation;
        final thumbnail = session.cells.map((cell) => cell.displayImagePath).whereType<String>().firstOrNull;
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            selected: selected,
            selectedTileColor: colors.secondaryContainer,
            contentPadding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
            leading: Stack(
              alignment: Alignment.center,
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: colors.surfaceContainerHighest,
                  backgroundImage: thumbnail == null
                      ? null
                      : ResizeImage.resizeIfNeeded(96, null, FileImage(File(thumbnail))),
                  child: thumbnail == null ? Text(session.name.isEmpty ? '?' : session.name[0].toUpperCase()) : null,
                ),
                if (generation.hasWork)
                  SizedBox.square(
                    dimension: 52,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      value: generation.current?.fraction.clamp(0.02, 1.0),
                    ),
                  ),
              ],
            ),
            title: Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              generation.hasWork
                  ? generation.summary
                  : '${session.cells.length} cells · ${session.settings.platform.label} · '
                        '${ImageTimestamps.formatShort(session.metadata.updatedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: selected ? Icon(Icons.check_circle, color: colors.primary) : null,
            onTap: onTap,
          ),
        );
      },
    );
  }
}
