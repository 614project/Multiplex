import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/path_safety.dart';
import '../generation/generation_context.dart';
import '../models/project_data.dart';

/// Live state of one prompt cell. Editable fields report changes through [onEdited] so the project
/// can autosave; transient fields (busy, live preview) only notify listeners.
class CellModel extends ChangeNotifier {
  CellModel({
    required this.id,
    int order = 0,
    String name = '',
    String prompt = '',
    int? overrideSteps,
    double? overrideCfgScale,
    int? overrideWidth,
    int? overrideHeight,
    String overrideNegativePrompt = '',
    String? lastImagePath,
    String? representativeImagePath,
  })  : _order = order,
        _name = name,
        _prompt = prompt,
        _overrideSteps = overrideSteps,
        _overrideCfgScale = overrideCfgScale,
        _overrideWidth = overrideWidth,
        _overrideHeight = overrideHeight,
        _overrideNegativePrompt = overrideNegativePrompt,
        _lastImagePath = lastImagePath,
        _representativeImagePath = representativeImagePath {
    _refreshDisplayImage();
  }

  /// Creates the model from stored data; relative image paths are resolved inside [projectFolder]
  /// and dropped when they would point outside of it.
  factory CellModel.fromData(CellData data, String projectFolder) => CellModel(
        id: data.id,
        order: data.order,
        name: data.name,
        prompt: data.prompt,
        overrideSteps: data.overrideSteps,
        overrideCfgScale: data.overrideCfgScale,
        overrideWidth: data.overrideWidth,
        overrideHeight: data.overrideHeight,
        overrideNegativePrompt: data.overrideNegativePrompt,
        lastImagePath: PathSafety.tryResolveWithinRoot(projectFolder, data.lastImagePath),
        representativeImagePath: PathSafety.tryResolveWithinRoot(projectFolder, data.representativeImagePath),
      );

  final String id;
  VoidCallback? onEdited;
  VoidCallback? onSelectionChanged;

  int _order;
  String _name;
  String _prompt;
  int? _overrideSteps;
  double? _overrideCfgScale;
  int? _overrideWidth;
  int? _overrideHeight;
  String _overrideNegativePrompt;
  String? _lastImagePath;
  String? _representativeImagePath;
  String? _displayImagePath;
  bool _isSelected = false;
  bool _isBusy = false;
  Uint8List? _livePreview;
  double? _liveProgress;
  int _imagesRevision = 0;

  int get order => _order;
  set order(int value) {
    if (_order != value) {
      _order = value;
      notifyListeners();
    }
  }

  String get defaultName => 'Cell ${_order + 1}';
  String get displayName => _name.trim().isEmpty ? defaultName : _name;

  String get name => _name;
  set name(String value) => _edit(() => _name = value, _name != value);

  String get prompt => _prompt;
  set prompt(String value) => _edit(() => _prompt = value, _prompt != value);

  int? get overrideSteps => _overrideSteps;
  double? get overrideCfgScale => _overrideCfgScale;
  int? get overrideWidth => _overrideWidth;
  int? get overrideHeight => _overrideHeight;
  String get overrideNegativePrompt => _overrideNegativePrompt;

  bool get hasOverrides =>
      _overrideSteps != null ||
      _overrideCfgScale != null ||
      _overrideWidth != null ||
      _overrideHeight != null ||
      _overrideNegativePrompt.trim().isNotEmpty;

  /// Short labels of the active overrides, for chips on the cell card.
  List<String> get overrideLabels => [
        if (_overrideSteps != null) '$_overrideSteps steps',
        if (_overrideCfgScale != null) 'CFG ${_formatNumber(_overrideCfgScale!)}',
        if (_overrideWidth != null || _overrideHeight != null) '${_overrideWidth ?? '·'}×${_overrideHeight ?? '·'}',
        if (_overrideNegativePrompt.trim().isNotEmpty) '+ negative',
      ];

  void setOverrides({
    required int? steps,
    required double? cfgScale,
    required int? width,
    required int? height,
    required String negativePrompt,
  }) {
    final changed = steps != _overrideSteps ||
        cfgScale != _overrideCfgScale ||
        width != _overrideWidth ||
        height != _overrideHeight ||
        negativePrompt != _overrideNegativePrompt;
    _edit(() {
      _overrideSteps = steps != null && steps > 0 ? steps : null;
      _overrideCfgScale = cfgScale != null && cfgScale > 0 ? cfgScale : null;
      _overrideWidth = width != null && width > 0 ? width : null;
      _overrideHeight = height != null && height > 0 ? height : null;
      _overrideNegativePrompt = negativePrompt.trim();
    }, changed);
  }

  String? get lastImagePath => _lastImagePath;
  set lastImagePath(String? value) => _edit(() {
        _lastImagePath = value;
        _refreshDisplayImage();
      }, _lastImagePath != value);

  String? get representativeImagePath => _representativeImagePath;
  set representativeImagePath(String? value) => _edit(() {
        _representativeImagePath = value;
        _refreshDisplayImage();
      }, _representativeImagePath != value);

  /// The representative image when it exists, otherwise the newest image.
  String? get displayImagePath => _displayImagePath;
  bool get hasImage => _displayImagePath != null;

  bool get isSelected => _isSelected;
  set isSelected(bool value) {
    if (_isSelected != value) {
      _isSelected = value;
      notifyListeners();
      onSelectionChanged?.call();
    }
  }

  bool get isBusy => _isBusy;
  set isBusy(bool value) {
    if (_isBusy != value) {
      _isBusy = value;
      if (!value) {
        _livePreview = null;
        _liveProgress = null;
      }

      notifyListeners();
    }
  }

  Uint8List? get livePreview => _livePreview;
  double? get liveProgress => _liveProgress;

  void setLivePreview(Uint8List? preview, double? progress) {
    if (preview == null && progress == _liveProgress) {
      return;
    }

    _livePreview = preview ?? _livePreview;
    _liveProgress = progress;
    notifyListeners();
  }

  /// Bumped whenever images are added or removed, so galleries know to reload.
  int get imagesRevision => _imagesRevision;
  void markImagesChanged() {
    _imagesRevision++;
    _refreshDisplayImage();
    notifyListeners();
  }

  void _edit(VoidCallback apply, bool changed) {
    if (!changed) {
      return;
    }

    apply();
    notifyListeners();
    onEdited?.call();
  }

  void _refreshDisplayImage() {
    String? resolved;
    for (final candidate in [_representativeImagePath, _lastImagePath]) {
      if (candidate != null && File(candidate).existsSync()) {
        resolved = candidate;
        break;
      }
    }

    _displayImagePath = resolved;
  }

  CellData toData(String projectFolder) => CellData(
        id: id,
        order: _order,
        name: displayName,
        prompt: _prompt,
        overrideSteps: _overrideSteps,
        overrideCfgScale: _overrideCfgScale,
        overrideWidth: _overrideWidth,
        overrideHeight: _overrideHeight,
        overrideNegativePrompt: _overrideNegativePrompt,
        lastImagePath: _relative(projectFolder, _lastImagePath),
        representativeImagePath: _relative(projectFolder, _representativeImagePath),
      );

  CellSnapshot snapshot() => CellSnapshot(
        id: id,
        displayName: displayName,
        prompt: _prompt,
        overrideSteps: _overrideSteps,
        overrideCfgScale: _overrideCfgScale,
        overrideWidth: _overrideWidth,
        overrideHeight: _overrideHeight,
        overrideNegativePrompt: _overrideNegativePrompt,
      );

  static String? _relative(String projectFolder, String? fullPath) =>
      fullPath == null ? null : PathSafety.toPortableRelative(projectFolder, fullPath);

  static String _formatNumber(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();
}
