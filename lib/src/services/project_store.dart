import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/project_data.dart';
import '../models/project_settings.dart';
import 'app_log.dart';
import 'app_paths.dart';
import 'file_io.dart';

/// Stores each project as `projects/<id>/project.json` next to its generated images.
///
/// Saves are serialized per project and numbered in the order the snapshots were taken, so a slow
/// write can never overwrite newer data. A project that is being removed accepts no more writes,
/// so a late autosave cannot recreate a deleted folder.
class ProjectStore {
  ProjectStore(this.paths);

  final AppPaths paths;
  final Map<String, Future<void>> _writeChains = {};
  final Map<String, int> _writtenVersions = {};
  final Set<String> _removing = {};
  int _nextVersion = 0;

  static String defaultProjectName([DateTime? now]) {
    final time = now ?? DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'Project ${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}${two(time.minute)}';
  }

  /// Reads every project. A project whose file cannot be read is skipped and reported through
  /// [unreadableProjectIds] instead of failing the whole list.
  Future<List<ProjectData>> loadAll({List<String>? unreadableProjectIds}) async {
    final root = Directory(paths.projectsRoot);
    if (!await root.exists()) {
      return [];
    }

    final projects = <ProjectData>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }

      final id = p.basename(entity.path);
      final file = File(paths.projectFile(id));
      if (!await file.exists()) {
        continue;
      }

      try {
        projects.add(await load(id));
      } catch (error, stackTrace) {
        AppLog.write('Reading project $id', error, stackTrace);
        unreadableProjectIds?.add(id);
      }
    }

    projects.sort((a, b) => b.metadata.updatedAt.compareTo(a.metadata.updatedAt));
    return projects;
  }

  Future<ProjectData> load(String projectId) async {
    final json = await FileIo.readJson(paths.projectFile(projectId));
    final data = ProjectData.fromJson(json, fallbackId: projectId);
    if (data.metadata.name.trim().isEmpty) {
      data.metadata.name = defaultProjectName(data.metadata.createdAt);
    }

    if (data.cells.isEmpty) {
      data.cells.addAll(ProjectData.createDefaultCells());
    }

    for (var index = 0; index < data.cells.length; index++) {
      data.cells[index].order = index;
      if (data.cells[index].name.trim().isEmpty) {
        data.cells[index].name = 'Cell ${index + 1}';
      }
    }

    return data;
  }

  Future<ProjectData> create(String name, {ProjectSettings? settings, List<CellData>? cells}) async {
    final data = ProjectData(
      metadata: ProjectMetadata.create(name.trim().isEmpty ? defaultProjectName() : name.trim()),
      settings: settings ?? ProjectSettings(),
      cells: cells == null || cells.isEmpty ? ProjectData.createDefaultCells() : cells,
    );
    await save(data);
    return data;
  }

  /// Copies a project, including its generated images. Cell ids are kept so the stored image
  /// paths stay valid inside the new folder.
  Future<ProjectData> clone(ProjectData source) async {
    final metadata = ProjectMetadata.create('${source.metadata.name} Copy');
    final clone = ProjectData.fromJson(source.toJson(), fallbackId: metadata.id);
    final data = ProjectData(metadata: metadata, settings: clone.settings, cells: clone.cells);

    final sourceCells = Directory(p.join(paths.projectFolder(source.metadata.id), 'cells'));
    if (await sourceCells.exists()) {
      await FileIo.copyDirectory(sourceCells, Directory(p.join(paths.projectFolder(metadata.id), 'cells')));
    }

    await save(data);
    return data;
  }

  /// Queues a write of [data]. The JSON snapshot is taken synchronously, so later edits to [data]
  /// do not leak into this write. Returns false when the write was skipped.
  Future<bool> save(ProjectData data) {
    final projectId = data.metadata.id;
    final version = ++_nextVersion;
    final json = const JsonEncoder.withIndent('  ').convert(data.toJson());
    final previous = _writeChains[projectId] ?? Future<void>.value();
    final write = previous.then((_) async {
      if (_removing.contains(projectId) || (_writtenVersions[projectId] ?? 0) >= version) {
        return false;
      }

      await FileIo.writeStringAtomic(paths.projectFile(projectId), json);
      _writtenVersions[projectId] = version;
      return true;
    });
    _writeChains[projectId] = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  /// Blocks further writes of the project and waits for the one in flight.
  Future<void> prepareRemoval(String projectId) async {
    _removing.add(projectId);
    await (_writeChains[projectId] ?? Future<void>.value());
  }

  void abortRemoval(String projectId) => _removing.remove(projectId);

  Future<void> delete(String projectId) async {
    await prepareRemoval(projectId);
    final folder = Directory(paths.projectFolder(projectId));
    if (await folder.exists()) {
      await folder.delete(recursive: true);
    }

    unawaited(_writeChains.remove(projectId));
    _writtenVersions.remove(projectId);
  }

  /// Waits until every queued write has finished.
  Future<void> flush() async {
    await Future.wait(_writeChains.values.toList());
  }
}
