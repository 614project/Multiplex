import 'dart:convert';

import '../core/ids.dart';
import '../core/json_read.dart';
import '../core/path_safety.dart';
import '../core/url_tools.dart';
import '../models/project_data.dart';
import '../models/project_settings.dart';

/// A project read from an import file, before it is given an id and stored.
class ImportedProject {
  ImportedProject({required this.name, required this.settings, required this.cells});

  final String name;
  final ProjectSettings settings;
  final List<CellData> cells;
}

/// JSON import/export of single projects and multi-project bundles.
///
/// Files use the WebuiMultiflex layout (PascalCase keys, `Settings` and `Cells`), so projects can move
/// between WebuiMultiflex and Multiplex in both directions. Exports never contain `user:password@`.
abstract final class ProjectTransfer {
  static const projectFormat = 'Multiplex.Project';
  static const bundleFormat = 'Multiplex.ProjectBundle';
  static const version = 4;

  static String serializeProject(ProjectData project) =>
      const JsonEncoder.withIndent('  ').convert(_exportProject(project));

  static String serializeProjects(Iterable<ProjectData> projects) =>
      const JsonEncoder.withIndent('  ')
          .convert({'Format': bundleFormat, 'Version': version, 'Projects': projects.map(_exportProject).toList()});

  static List<ImportedProject> deserialize(String jsonContent) {
    if (jsonContent.trim().isEmpty) {
      throw const FormatException('Project JSON is empty.');
    }

    final root = jsonDecode(jsonContent);
    final List<Object?> entries;
    if (root is List) {
      entries = root.cast<Object?>();
    } else if (JsonRead.map(root) case final map?) {
      final bundle = JsonRead.list(JsonRead.value(map, 'projects'));
      entries = bundle != null && bundle.isNotEmpty ? bundle : [map];
    } else {
      throw const FormatException('Unsupported project JSON format.');
    }

    final projects = <ImportedProject>[];
    for (final entry in entries) {
      final map = JsonRead.map(entry);
      if (map == null) {
        continue;
      }

      projects.add(_importProject(map));
    }

    if (projects.isEmpty) {
      throw const FormatException('No projects were found in the JSON file.');
    }

    return projects;
  }

  static ImportedProject _importProject(Map<String, Object?> map) {
    final settings = ProjectSettings.fromJson(JsonRead.value(map, 'settings'));
    final rawCells = JsonRead.list(JsonRead.value(map, 'cells')) ?? const [];
    final parsed = <CellData>[
      for (var index = 0; index < rawCells.length; index++) CellData.fromJson(rawCells[index], fallbackOrder: index),
    ]..sort((a, b) => a.order.compareTo(b.order));

    final cells = <CellData>[];
    for (var index = 0; index < parsed.length; index++) {
      final cell = parsed[index];
      cells.add(
        CellData(
          id: newId(),
          order: index,
          name: cell.name.trim().isEmpty ? 'Cell ${index + 1}' : cell.name,
          prompt: cell.prompt,
          overrideSteps: cell.overrideSteps,
          overrideCfgScale: cell.overrideCfgScale,
          overrideWidth: cell.overrideWidth,
          overrideHeight: cell.overrideHeight,
          overrideNegativePrompt: cell.overrideNegativePrompt,
          // Imported files are untrusted: keep an image reference only when it stays inside the project folder.
          representativeImagePath: PathSafety.isSafeRelativePath(cell.representativeImagePath)
              ? cell.representativeImagePath
              : null,
        ),
      );
    }

    return ImportedProject(name: (JsonRead.string(map, 'name') ?? '').trim(), settings: settings, cells: cells);
  }

  static Map<String, Object?> _exportProject(ProjectData project) {
    final settings = project.settings.copy()..apiBaseUrl = UrlCredentials.remove(project.settings.apiBaseUrl);
    final cells = [...project.cells]..sort((a, b) => a.order.compareTo(b.order));
    return {
      'Format': projectFormat,
      'Version': version,
      'Name': project.metadata.name,
      'Settings': _pascal(settings.toJson()),
      'Cells': [
        for (final cell in cells)
          {
            'Order': cell.order,
            'Name': cell.name,
            'Prompt': cell.prompt,
            'OverrideSteps': cell.overrideSteps,
            'OverrideCfgScale': cell.overrideCfgScale,
            'OverrideWidth': cell.overrideWidth,
            'OverrideHeight': cell.overrideHeight,
            'OverrideNegativePrompt': cell.overrideNegativePrompt,
            'RepresentativeImagePath': cell.representativeImagePath,
          },
      ],
    };
  }

  static Object? _pascal(Object? value) {
    if (value is Map) {
      return {for (final entry in value.entries) _capitalize(entry.key.toString()): _pascal(entry.value)};
    }

    if (value is List) {
      return value.map(_pascal).toList();
    }

    return value;
  }

  static String _capitalize(String key) => key.isEmpty ? key : key[0].toUpperCase() + key.substring(1);
}
