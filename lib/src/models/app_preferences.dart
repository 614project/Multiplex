import 'package:flutter/material.dart';

import '../core/json_read.dart';
import 'api_platform.dart';

enum CellLayout { list, grid }

/// App-wide preferences, persisted as `preferences.json`.
class AppPreferences {
  AppPreferences({
    this.themeMode = ThemeMode.system,
    this.seedColor = defaultSeedColor,
    this.useDynamicColor = true,
    this.cellLayout = CellLayout.list,
    this.mobileCellColumns = 2,
    this.globalApiBaseUrl = '',
    this.defaultTimeoutSeconds = defaultTimeout,
    this.defaultGenerationMode = GenerationModes.standard,
    this.defaultClipSkip = 1,
    this.globalCommonPrompt = '',
    this.globalNegativePrompt = '',
    this.pollingRecoveryGraceSeconds = 4,
    this.livePreviewEnabled = true,
    this.listCellHeight = 228,
    this.gridCellWidth = 420,
    this.cellDetailGalleryWidth = 420,
    this.promptAutocompleteEnabled = true,
    this.lastProjectId = '',
    this.projectsPaneExpanded = true,
  });

  static const defaultSeedColor = 0xFF5B5BD6;
  static const defaultTimeout = 600;
  static const minListCellHeight = 160;
  static const maxListCellHeight = 420;
  static const minGridCellWidth = 280;
  static const maxGridCellWidth = 640;
  static const minGalleryWidth = 280;
  static const maxGalleryWidth = 1400;

  ThemeMode themeMode;
  int seedColor;
  bool useDynamicColor;
  CellLayout cellLayout;
  int mobileCellColumns;
  String globalApiBaseUrl;
  int defaultTimeoutSeconds;
  String defaultGenerationMode;
  int defaultClipSkip;
  String globalCommonPrompt;
  String globalNegativePrompt;
  int pollingRecoveryGraceSeconds;
  bool livePreviewEnabled;
  int listCellHeight;
  int gridCellWidth;
  int cellDetailGalleryWidth;
  bool promptAutocompleteEnabled;
  String lastProjectId;
  bool projectsPaneExpanded;

  void normalize() {
    globalApiBaseUrl = globalApiBaseUrl.trim();
    defaultTimeoutSeconds = defaultTimeoutSeconds <= 0 ? defaultTimeout : defaultTimeoutSeconds;
    defaultGenerationMode = GenerationModes.all.contains(defaultGenerationMode)
        ? defaultGenerationMode
        : GenerationModes.standard;
    defaultClipSkip = defaultClipSkip.clamp(1, 24);
    pollingRecoveryGraceSeconds = pollingRecoveryGraceSeconds.clamp(0, 30);
    listCellHeight = listCellHeight.clamp(minListCellHeight, maxListCellHeight);
    gridCellWidth = gridCellWidth.clamp(minGridCellWidth, maxGridCellWidth);
    cellDetailGalleryWidth = cellDetailGalleryWidth.clamp(minGalleryWidth, maxGalleryWidth);
    mobileCellColumns = mobileCellColumns.clamp(1, 3);
  }

  Map<String, Object?> toJson() => {
        'themeMode': themeMode.name,
        'seedColor': seedColor,
        'useDynamicColor': useDynamicColor,
        'cellLayout': cellLayout.name,
        'mobileCellColumns': mobileCellColumns,
        'globalApiBaseUrl': globalApiBaseUrl,
        'defaultTimeoutSeconds': defaultTimeoutSeconds,
        'defaultGenerationMode': defaultGenerationMode,
        'defaultClipSkip': defaultClipSkip,
        'globalCommonPrompt': globalCommonPrompt,
        'globalNegativePrompt': globalNegativePrompt,
        'pollingRecoveryGraceSeconds': pollingRecoveryGraceSeconds,
        'livePreviewEnabled': livePreviewEnabled,
        'listCellHeight': listCellHeight,
        'gridCellWidth': gridCellWidth,
        'cellDetailGalleryWidth': cellDetailGalleryWidth,
        'promptAutocompleteEnabled': promptAutocompleteEnabled,
        'lastProjectId': lastProjectId,
        'projectsPaneExpanded': projectsPaneExpanded,
      };

  factory AppPreferences.fromJson(Object? json) {
    final map = JsonRead.map(json) ?? const <String, Object?>{};
    final defaults = AppPreferences();
    final preferences = AppPreferences(
      themeMode: ThemeMode.values.firstWhere(
        (mode) => mode.name == JsonRead.string(map, 'themeMode'),
        orElse: () => defaults.themeMode,
      ),
      seedColor: JsonRead.integer(map, 'seedColor') ?? defaults.seedColor,
      useDynamicColor: JsonRead.boolean(map, 'useDynamicColor') ?? defaults.useDynamicColor,
      cellLayout: CellLayout.values.firstWhere(
        (layout) => layout.name == JsonRead.string(map, 'cellLayout'),
        orElse: () => defaults.cellLayout,
      ),
      mobileCellColumns: JsonRead.integer(map, 'mobileCellColumns') ?? defaults.mobileCellColumns,
      globalApiBaseUrl: JsonRead.string(map, 'globalApiBaseUrl') ?? '',
      defaultTimeoutSeconds: JsonRead.integer(map, 'defaultTimeoutSeconds') ?? defaults.defaultTimeoutSeconds,
      defaultGenerationMode: JsonRead.string(map, 'defaultGenerationMode') ?? defaults.defaultGenerationMode,
      defaultClipSkip: JsonRead.integer(map, 'defaultClipSkip') ?? defaults.defaultClipSkip,
      globalCommonPrompt: JsonRead.string(map, 'globalCommonPrompt') ?? '',
      globalNegativePrompt: JsonRead.string(map, 'globalNegativePrompt') ?? '',
      pollingRecoveryGraceSeconds:
          JsonRead.integer(map, 'pollingRecoveryGraceSeconds') ?? defaults.pollingRecoveryGraceSeconds,
      livePreviewEnabled: JsonRead.boolean(map, 'livePreviewEnabled') ?? defaults.livePreviewEnabled,
      listCellHeight: JsonRead.integer(map, 'listCellHeight') ?? defaults.listCellHeight,
      gridCellWidth: JsonRead.integer(map, 'gridCellWidth') ?? defaults.gridCellWidth,
      cellDetailGalleryWidth: JsonRead.integer(map, 'cellDetailGalleryWidth') ?? defaults.cellDetailGalleryWidth,
      promptAutocompleteEnabled:
          JsonRead.boolean(map, 'promptAutocompleteEnabled') ?? defaults.promptAutocompleteEnabled,
      lastProjectId: JsonRead.string(map, 'lastProjectId') ?? '',
      projectsPaneExpanded: JsonRead.boolean(map, 'projectsPaneExpanded') ?? defaults.projectsPaneExpanded,
    );
    preferences.normalize();
    return preferences;
  }
}
