import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../core/json_read.dart';
import '../core/path_safety.dart';
import '../core/url_tools.dart';
import '../models/img2img.dart';
import '../models/project_data.dart';
import '../models/project_settings.dart';
import 'source_images.dart';

/// A project read from an import file, before it is given an id and stored.
class ImportedProject {
  ImportedProject({required this.name, required this.settings, required this.cells, this.sourceImages = const {}});

  final String name;
  final ProjectSettings settings;
  final List<CellData> cells;

  /// img2img source images carried in the file, keyed by their path relative to the project folder.
  final Map<String, Uint8List> sourceImages;
}

/// JSON import/export of single projects and multi-project bundles.
///
/// Files use the WebuiMultiflex layout (PascalCase keys, `Settings` and `Cells`), so projects can move
/// between WebuiMultiflex and Multiplex in both directions. Exports never contain `user:password@`.
/// img2img source images are embedded as base64 under `SourceImages`, which WebuiMultiflex ignores.
abstract final class ProjectTransfer {
  static const projectFormat = 'Multiplex.Project';
  static const bundleFormat = 'Multiplex.ProjectBundle';
  static const version = 4;

  /// [sourceImages] are the project's img2img source images keyed by their relative path
  /// (see `ProjectSession.readSourceImages`).
  static String serializeProject(ProjectData project, {Map<String, Uint8List> sourceImages = const {}}) =>
      const JsonEncoder.withIndent('  ').convert(_exportProject(project, sourceImages));

  /// [sourceImages] maps project ids to their source images.
  static String serializeProjects(
    Iterable<ProjectData> projects, {
    Map<String, Map<String, Uint8List>> sourceImages = const {},
  }) => const JsonEncoder.withIndent('  ').convert({
    'Format': bundleFormat,
    'Version': version,
    'Projects': [
      for (final project in projects) _exportProject(project, sourceImages[project.metadata.id] ?? const {}),
    ],
  });

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
    final sourceImages = _readSourceImages(JsonRead.value(map, 'sourceImages'));
    // References to source images the file does not carry would only show up as missing images.
    if (!sourceImages.containsKey(settings.sourceImagePath)) {
      settings.sourceImagePath = '';
    }

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
          sourceImagePath: sourceImages.containsKey(cell.sourceImagePath) ? cell.sourceImagePath : null,
          overrideDenoisingStrength: cell.overrideDenoisingStrength,
          // Imported files are untrusted: keep an image reference only when it stays inside the project folder.
          representativeImagePath: PathSafety.isSafeRelativePath(cell.representativeImagePath)
              ? cell.representativeImagePath
              : null,
        ),
      );
    }

    return ImportedProject(
      name: (JsonRead.string(map, 'name') ?? '').trim(),
      settings: settings,
      cells: cells,
      sourceImages: sourceImages,
    );
  }

  /// Keeps only entries that are images and stay inside the project's source folder.
  static Map<String, Uint8List> _readSourceImages(Object? json) {
    final map = JsonRead.map(json);
    if (map == null) {
      return const {};
    }

    final images = <String, Uint8List>{};
    for (final MapEntry(:key, :value) in map.entries) {
      final path = key.replaceAll('\\', '/');
      if (!PathSafety.isSafeRelativePath(path) || !path.startsWith('${Img2ImgDefaults.sourceFolderName}/')) {
        continue;
      }

      if (value is! String) {
        continue;
      }

      try {
        final bytes = base64.decode(value);
        if (SourceImages.readInfo(bytes) != null) {
          images[path] = bytes;
        }
      } on FormatException {
        continue;
      }
    }

    return images;
  }

  static Map<String, Object?> _exportProject(ProjectData project, Map<String, Uint8List> sourceImages) {
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
            'SourceImagePath': cell.sourceImagePath,
            'OverrideDenoisingStrength': cell.overrideDenoisingStrength,
          },
      ],
      if (sourceImages.isNotEmpty)
        'SourceImages': {for (final MapEntry(:key, :value) in sourceImages.entries) key: base64.encode(value)},
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
