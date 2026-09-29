import '../core/ids.dart';
import '../core/json_read.dart';
import 'project_settings.dart';

class ProjectMetadata {
  ProjectMetadata({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.lastOpenedAt,
  });

  factory ProjectMetadata.create(String name) {
    final now = DateTime.now();
    return ProjectMetadata(
      id: newId(),
      name: name,
      createdAt: now,
      updatedAt: now,
      lastOpenedAt: now,
    );
  }

  final String id;
  String name;
  DateTime createdAt;
  DateTime updatedAt;
  DateTime lastOpenedAt;

  ProjectMetadata copy() => ProjectMetadata(
        id: id,
        name: name,
        createdAt: createdAt,
        updatedAt: updatedAt,
        lastOpenedAt: lastOpenedAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'lastOpenedAt': lastOpenedAt.toUtc().toIso8601String(),
      };

  static ProjectMetadata fromJson(Object? json, {required String fallbackId}) {
    final map = JsonRead.map(json) ?? const <String, Object?>{};
    final now = DateTime.now();
    final id = JsonRead.string(map, 'id');
    return ProjectMetadata(
      id: id == null || id.isEmpty ? fallbackId : id,
      name: JsonRead.string(map, 'name') ?? '',
      createdAt: JsonRead.dateTime(map, 'createdAt') ?? now,
      updatedAt: JsonRead.dateTime(map, 'updatedAt') ?? now,
      lastOpenedAt: JsonRead.dateTime(map, 'lastOpenedAt') ?? now,
    );
  }
}

/// One prompt cell as it is stored on disk. Image paths are relative to the project folder.
class CellData {
  CellData({
    required this.id,
    this.order = 0,
    this.name = '',
    this.prompt = '',
    this.overrideSteps,
    this.overrideCfgScale,
    this.overrideWidth,
    this.overrideHeight,
    this.overrideNegativePrompt = '',
    this.lastImagePath,
    this.representativeImagePath,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  int order;
  String name;
  String prompt;
  int? overrideSteps;
  double? overrideCfgScale;
  int? overrideWidth;
  int? overrideHeight;
  String overrideNegativePrompt;
  String? lastImagePath;
  String? representativeImagePath;
  DateTime updatedAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'order': order,
        'name': name,
        'prompt': prompt,
        'overrideSteps': overrideSteps,
        'overrideCfgScale': overrideCfgScale,
        'overrideWidth': overrideWidth,
        'overrideHeight': overrideHeight,
        'overrideNegativePrompt': overrideNegativePrompt,
        'lastImagePath': lastImagePath,
        'representativeImagePath': representativeImagePath,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  /// Reads Multiplex cells as well as WebuiMultiflex `ExportedCell` objects.
  static CellData fromJson(Object? json, {int fallbackOrder = 0}) {
    final map = JsonRead.map(json) ?? const <String, Object?>{};
    final id = JsonRead.string(map, 'id');
    return CellData(
      id: id == null || id.isEmpty ? newId() : id,
      order: JsonRead.integer(map, 'order') ?? fallbackOrder,
      name: JsonRead.string(map, 'name') ?? '',
      prompt: JsonRead.string(map, 'prompt') ?? '',
      overrideSteps: _positiveInt(JsonRead.integer(map, 'overrideSteps')),
      overrideCfgScale: _positiveDouble(JsonRead.number(map, 'overrideCfgScale')?.toDouble()),
      overrideWidth: _positiveInt(JsonRead.integer(map, 'overrideWidth')),
      overrideHeight: _positiveInt(JsonRead.integer(map, 'overrideHeight')),
      overrideNegativePrompt: JsonRead.string(map, 'overrideNegativePrompt') ?? '',
      lastImagePath: JsonRead.string(map, 'lastImagePath'),
      representativeImagePath: JsonRead.string(map, 'representativeImagePath'),
      updatedAt: JsonRead.dateTime(map, 'updatedAt'),
    );
  }

  static int? _positiveInt(int? value) => value != null && value > 0 ? value : null;

  static double? _positiveDouble(double? value) =>
      value != null && !value.isNaN && !value.isInfinite && value > 0 ? value : null;
}

class ProjectData {
  ProjectData({required this.metadata, required this.settings, required this.cells});

  final ProjectMetadata metadata;
  final ProjectSettings settings;
  final List<CellData> cells;

  static const defaultCellCount = 4;

  static List<CellData> createDefaultCells() => List.generate(
        defaultCellCount,
        (index) => CellData(id: newId(), order: index, name: 'Cell ${index + 1}'),
      );

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'metadata': metadata.toJson(),
        'settings': settings.toJson(),
        'cells': cells.map((cell) => cell.toJson()).toList(),
      };

  static ProjectData fromJson(Object? json, {required String fallbackId}) {
    final map = JsonRead.map(json) ?? const <String, Object?>{};
    final rawCells = JsonRead.list(JsonRead.value(map, 'cells')) ?? const [];
    final cells = <CellData>[
      for (var index = 0; index < rawCells.length; index++)
        CellData.fromJson(rawCells[index], fallbackOrder: index),
    ]..sort((a, b) => a.order.compareTo(b.order));

    return ProjectData(
      metadata: ProjectMetadata.fromJson(JsonRead.value(map, 'metadata'), fallbackId: fallbackId),
      settings: ProjectSettings.fromJson(JsonRead.value(map, 'settings')),
      cells: cells,
    );
  }
}
