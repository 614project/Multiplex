import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/sd_client.dart';
import '../core/path_safety.dart';
import '../services/project_transfer.dart';
import '../state/app_state.dart';
import '../state/cell_model.dart';
import '../state/project_session.dart';
import 'common/dialogs.dart';
import 'dialogs/cell_dialogs.dart';
import 'layout.dart';
import 'platform_actions.dart';

/// Project level commands shared by the desktop and mobile layouts.
abstract final class ProjectActions {
  static AppState _app(BuildContext context) => context.read<AppState>();

  static Future<void> rename(BuildContext context, ProjectSession session) async {
    final name = await showTextInputDialog(
      context,
      title: 'Rename project',
      initialValue: session.name,
      label: 'Project name',
    );
    if (name != null) {
      session.rename(name);
    }
  }

  static Future<void> renameCell(BuildContext context, CellModel cell) async {
    final name = await showTextInputDialog(
      context,
      title: 'Rename cell',
      initialValue: cell.displayName,
      label: 'Cell name',
    );
    if (name != null) {
      cell.name = name;
    }
  }

  static Future<void> saveNow(BuildContext context, ProjectSession session) async {
    await session.saveNow();
    if (context.mounted) {
      _app(context).messenger.success('Project saved.');
    }
  }

  static Future<void> clone(BuildContext context, ProjectSession session) => _app(context).cloneProject(session);

  static Future<void> remove(BuildContext context, ProjectSession session) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove project',
      message: 'Remove "${session.name}" and all of its generated images? This cannot be undone.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (confirmed && context.mounted) {
      await _app(context).removeProject(session);
    }
  }

  static Future<void> export(BuildContext context, ProjectSession session) async {
    final app = _app(context);
    await session.saveNow();
    final json = ProjectTransfer.serializeProject(session.snapshot(), sourceImages: await session.readSourceImages());
    final fileName = '${PathSafety.sanitizeFileName(session.name, fallback: 'Project')}.json';
    if (!context.mounted) {
      return;
    }

    try {
      if (await PlatformActions.saveJson(context, fileName, json)) {
        app.messenger.success('Project exported.');
      }
    } catch (error) {
      app.messenger.error('Export failed: ${SdClient.describeError(error)}');
    }
  }

  static Future<void> exportAll(BuildContext context) async {
    final app = _app(context);
    try {
      final json = await app.exportAllProjects();
      if (!context.mounted) {
        return;
      }

      final now = DateTime.now();
      final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      if (await PlatformActions.saveJson(context, 'Multiplex-projects-$stamp.json', json)) {
        app.messenger.success('Exported ${app.projects.length} projects.');
      }
    } catch (error) {
      app.messenger.error('Export failed: ${SdClient.describeError(error)}');
    }
  }

  static Future<void> import(BuildContext context) async {
    final app = _app(context);
    try {
      final files = await PlatformActions.pickJsonFiles();
      for (final json in files) {
        await app.importProjects(json);
      }
    } catch (error) {
      app.messenger.error('Import failed: ${SdClient.describeError(error)}');
    }
  }

  /// Writes the shown image of the selected cells (or all cells) in a chosen format.
  static Future<void> collect(BuildContext context, ProjectSession session) async {
    final app = _app(context);
    final cells = session.generationTargets.where((cell) => cell.displayImagePath != null).toList();
    if (cells.isEmpty) {
      app.messenger.warning('No images were found to collect.');
      return;
    }

    final format = await showCollectFormatDialog(
      context,
      imageCount: cells.length,
      toGallery: PlatformInfo.canSaveToGallery,
    );
    if (format == null) {
      return;
    }

    try {
      final message = await PlatformActions.collect([
        for (final cell in cells) (name: cell.displayName, path: cell.displayImagePath!),
      ], format);
      if (message != null) {
        app.messenger.success(message);
      }
    } catch (error) {
      app.messenger.error('Failed to collect images: ${SdClient.describeError(error)}');
    }
  }

  static Future<void> openFolder(BuildContext context, String folder) async {
    try {
      await PlatformActions.openFolder(folder);
    } catch (error) {
      if (context.mounted) {
        _app(context).messenger.error('Could not open the folder: $error');
      }
    }
  }

  static Future<void> removeCells(BuildContext context, ProjectSession session, List<CellModel> cells) async {
    if (cells.isEmpty) {
      return;
    }

    final withImages = cells.where((cell) => cell.hasImage).length;
    final confirmed = await showConfirmDialog(
      context,
      title: cells.length == 1 ? 'Remove cell' : 'Remove ${cells.length} cells',
      message: withImages == 0
          ? 'The prompt${cells.length == 1 ? '' : 's'} will be removed from the project.'
          : 'The cell${cells.length == 1 ? '' : 's'} will be removed from the project. Generated images stay in the project folder.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (confirmed) {
      session.removeCells(cells);
    }
  }
}
