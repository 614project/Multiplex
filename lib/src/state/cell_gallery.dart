import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/image_metadata.dart';
import '../services/png_metadata_reader.dart';
import 'cell_model.dart';
import 'project_session.dart';

/// Image history of one cell with multi-selection, as shown on the cell detail page.
class CellGallery extends ChangeNotifier {
  CellGallery(this.session, this.cell) {
    _revision = cell.imagesRevision;
    cell.addListener(_onCellChanged);
  }

  final ProjectSession session;
  final CellModel cell;
  List<CellImage> images = [];
  final Set<String> _selected = {};
  String? _primary;
  String? _anchor;
  bool _loading = true;
  late int _revision;
  final Map<String, Future<GeneratedImageMetadata>> _metadata = {};

  bool get isLoading => _loading;
  bool get hasImages => images.isNotEmpty;
  Set<String> get selectedPaths => Set.unmodifiable(_selected);
  int get selectedCount => _selected.length;

  /// The image shown in the preview (the last one clicked).
  CellImage? get primary => images.where((image) => image.path == _primary).firstOrNull;
  int get primaryIndex => images.indexWhere((image) => image.path == _primary);

  List<CellImage> get selectedImages {
    final selected = images.where((image) => _selected.contains(image.path)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return selected;
  }

  bool isSelected(CellImage image) => _selected.contains(image.path);
  bool isRepresentative(CellImage image) => cell.representativeImagePath == image.path;

  String get imageCountText => images.length == 1 ? '1 image' : '${images.length} images';

  Future<void> load({String? preferredPath}) async {
    final previousSelection = {..._selected};
    final loaded = await session.listImages(cell);
    images = loaded;
    _metadata.removeWhere((path, _) => !loaded.any((image) => image.path == path));
    _selected
      ..clear()
      ..addAll(previousSelection.where((path) => loaded.any((image) => image.path == path)));

    final preferred = preferredPath ?? _primary ?? cell.displayImagePath;
    if (_selected.isEmpty) {
      final initial = loaded.where((image) => image.path == preferred).firstOrNull ?? loaded.firstOrNull;
      if (initial != null) {
        _selected.add(initial.path);
      }
    }

    _primary = _selected.contains(preferred) ? preferred : (_selected.isEmpty ? null : _selected.first);
    _anchor = _primary;
    _loading = false;
    notifyListeners();
  }

  /// Plain click: select only [image]. With [toggle] (Ctrl) flip it; with [range] (Shift) extend
  /// from the last clicked image.
  void select(CellImage image, {bool toggle = false, bool range = false}) {
    if (range && _anchor != null) {
      final from = images.indexWhere((candidate) => candidate.path == _anchor);
      final to = images.indexOf(image);
      if (from >= 0 && to >= 0) {
        _selected.clear();
        for (var index = math.min(from, to); index <= math.max(from, to); index++) {
          _selected.add(images[index].path);
        }

        _primary = image.path;
        notifyListeners();
        return;
      }
    }

    if (toggle) {
      if (!_selected.remove(image.path)) {
        _selected.add(image.path);
        _primary = image.path;
      } else if (_primary == image.path) {
        _primary = _selected.isEmpty ? null : _selected.last;
      }
    } else {
      _selected
        ..clear()
        ..add(image.path);
      _primary = image.path;
    }

    _anchor = image.path;
    notifyListeners();
  }

  /// Shows [image] in the preview without changing a multi-selection (used by the mobile pager).
  void show(CellImage image) {
    if (_selected.length <= 1) {
      _selected
        ..clear()
        ..add(image.path);
    }

    _primary = image.path;
    _anchor = image.path;
    notifyListeners();
  }

  void selectAll() {
    _selected
      ..clear()
      ..addAll(images.map((image) => image.path));
    notifyListeners();
  }

  void clearSelection({bool keepPrimary = true}) {
    _selected.clear();
    if (keepPrimary && _primary != null) {
      _selected.add(_primary!);
    }

    notifyListeners();
  }

  void step(int delta) {
    if (images.isEmpty) {
      return;
    }

    final current = primaryIndex < 0 ? 0 : primaryIndex;
    final next = (current + delta).clamp(0, images.length - 1);
    select(images[next]);
  }

  Future<GeneratedImageMetadata> metadataFor(CellImage image) =>
      _metadata.putIfAbsent(image.path, () => PngMetadataReader.readFile(image.path));

  void setRepresentative(CellImage? image) {
    session.setRepresentativeImage(cell, image?.path);
    notifyListeners();
  }

  Future<void> deleteSelected() async {
    final paths = [..._selected];
    if (paths.isEmpty) {
      return;
    }

    final index = primaryIndex;
    await session.deleteImages(cell, paths);
    _selected.clear();
    await load();
    if (_selected.isEmpty && images.isNotEmpty) {
      select(images[index.clamp(0, images.length - 1)]);
    }
  }

  void _onCellChanged() {
    if (cell.imagesRevision != _revision) {
      _revision = cell.imagesRevision;
      unawaited(load());
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    cell.removeListener(_onCellChanged);
    super.dispose();
  }
}
