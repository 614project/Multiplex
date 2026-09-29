import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../api/comfy_workflow.dart';
import '../api/sd_client.dart';
import '../api/sd_models.dart';
import '../core/cancellation.dart';
import '../core/ids.dart';
import '../core/image_signature.dart';
import '../core/image_timestamps.dart';
import '../core/option_lists.dart';
import '../generation/generation_context.dart';
import '../generation/generation_runner.dart';
import '../models/api_platform.dart';
import '../models/app_preferences.dart';
import '../models/lora_selection.dart';
import '../models/project_data.dart';
import '../models/project_settings.dart';
import '../services/app_log.dart';
import '../services/app_paths.dart';
import '../services/comfy_metadata_cache.dart';
import '../services/file_io.dart';
import '../services/project_store.dart';
import 'app_messenger.dart';
import 'cell_model.dart';

/// Services a project needs from the app.
abstract interface class SessionEnvironment {
  AppPaths get paths;
  ProjectStore get store;
  AppPreferences get preferences;
  AppMessenger get messenger;
  ComfyMetadataCache get comfyCache;
  WebUiMetadataCache get webUiCache;
  SdClient createClient();
  void projectChanged(ProjectSession session);
}

/// Sampler, scheduler and upscaler lists reported by WebUI endpoints, per base URL (in memory).
class WebUiMetadataCache {
  final Map<String, ({List<String> samplers, List<String> schedulers, List<String> upscalers})> _entries = {};

  ({List<String> samplers, List<String> schedulers, List<String> upscalers})? tryGet(String baseUrl) =>
      _entries[baseUrl.trim().toLowerCase()];

  void store(String baseUrl, List<String> samplers, List<String> schedulers, List<String> upscalers) {
    _entries[baseUrl.trim().toLowerCase()] = (samplers: samplers, schedulers: schedulers, upscalers: upscalers);
  }
}

enum ServerStatus { unknown, checking, online, offline }

class CellImage {
  CellImage(this.path, this.createdAt);

  final String path;
  final DateTime createdAt;

  String get fileName => p.basename(path);
}

/// Available LoRAs returned by the server.
class LoraCatalog {
  const LoraCatalog({required this.names, required this.loaderTypes});

  final List<String> names;
  final List<String> loaderTypes;
}

/// Live queue and progress of a project. Kept separate from [ProjectSession] so frequent progress
/// updates only rebuild the widgets that show them.
class GenerationState extends ChangeNotifier {
  final List<GenerationJob> pending = [];
  GenerationJob? current;
  bool isGenerating = false;
  bool stopAfterCurrentImageRequested = false;
  bool forceInterruptRequested = false;
  String statusText = 'Ready';
  Uint8List? preview;
  String? previewCellId;

  int get jobCount => pending.length + (current == null ? 0 : 1);
  bool get hasWork => jobCount > 0;
  bool get isInterrupting => stopAfterCurrentImageRequested || forceInterruptRequested;

  String get summary {
    if (current != null) {
      return statusText;
    }

    if (pending.isNotEmpty) {
      return pending.length == 1 ? '1 job queued' : '${pending.length} jobs queued';
    }

    return 'Ready';
  }

  void changed() => notifyListeners();
}

/// Everything about one open project: settings, cells, option lists, queue and autosave.
class ProjectSession extends ChangeNotifier implements GenerationHost {
  ProjectSession(this.env, ProjectData data)
      : metadata = data.metadata,
        settings = data.settings {
    for (final cell in data.cells) {
      _attach(CellModel.fromData(cell, projectFolder));
    }

    if (_cells.isEmpty) {
      for (final cell in ProjectData.createDefaultCells()) {
        _attach(CellModel.fromData(cell, projectFolder));
      }
    }

    _reindex();
    _initializeOptions();
  }

  static const metadataRequestTimeout = Duration(seconds: 30);
  static const autosaveDelay = Duration(milliseconds: 1500);
  static const metadataRefreshDelay = Duration(milliseconds: 700);

  final SessionEnvironment env;
  final ProjectMetadata metadata;
  final ProjectSettings settings;
  final List<CellModel> _cells = [];
  final GenerationState generation = GenerationState();

  List<String> samplerOptions = const [];
  List<String> schedulerOptions = const [];
  List<String> hiresUpscalerOptions = const [];
  bool isComfyMetadataLoading = false;
  ServerStatus serverStatus = ServerStatus.unknown;
  String serverMessage = '';
  int _generateRepeatCount = 1;

  SdClient? _client;
  GenerationRunner? _runner;
  CancellationSource? _jobCancellation;
  Future<void>? _queueProcessor;
  int _nextJobSequence = 1;
  bool _waitForWebUiIdle = false;
  Timer? _saveTimer;
  bool _dirty = false;
  bool _removed = false;
  bool _active = false;
  Timer? _metadataTimer;
  int _metadataRefreshVersion = 0;
  StreamSubscription<String>? _comfyCacheSubscription;

  String get id => metadata.id;
  String get name => metadata.name;
  String get projectFolder => env.paths.projectFolder(id);
  List<CellModel> get cells => List.unmodifiable(_cells);
  bool get isRemoved => _removed;

  // ---------------------------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------------------------

  /// The URL requests go to: the project URL, else the global URL, else the platform default.
  String get resolvedApiBaseUrl {
    if (settings.apiBaseUrl.trim().isNotEmpty) {
      return settings.apiBaseUrl.trim();
    }

    if (env.preferences.globalApiBaseUrl.trim().isNotEmpty) {
      return env.preferences.globalApiBaseUrl.trim();
    }

    return settings.platform.defaultBaseUrl;
  }

  String get apiBaseUrlPlaceholder => env.preferences.globalApiBaseUrl.trim().isNotEmpty
      ? env.preferences.globalApiBaseUrl.trim()
      : settings.platform.defaultBaseUrl;

  String get apiBaseUrlDescription => env.preferences.globalApiBaseUrl.trim().isNotEmpty
      ? 'Leave blank to use the global API base URL (${env.preferences.globalApiBaseUrl.trim()}).'
      : 'Leave blank to use the default ${settings.platform.label} endpoint (${settings.platform.defaultBaseUrl}).';

  String get checkpointDisplay => settings.checkpointModel.trim().isEmpty
      ? (settings.platform.isComfyUi ? 'First available ComfyUI checkpoint' : 'Current WebUI checkpoint')
      : settings.checkpointModel;

  int get effectiveTimeoutSeconds =>
      settings.timeoutSeconds > 0 ? settings.timeoutSeconds : env.preferences.defaultTimeoutSeconds;

  int get effectiveClipSkip => settings.clipSkip >= 1 ? settings.clipSkip.clamp(1, 24) : env.preferences.defaultClipSkip;

  String get effectiveGenerationMode => settings.generationMode.isEmpty
      ? GenerationModes.normalizeForPlatform(settings.platform, env.preferences.defaultGenerationMode)
      : GenerationModes.normalizeForPlatform(settings.platform, settings.generationMode);

  /// Applies an edit to the settings and schedules an autosave.
  void edit(void Function(ProjectSettings settings) change) {
    change(settings);
    _settingsChanged();
  }

  void setApiBaseUrl(String value) {
    final trimmed = value.trim();
    if (settings.apiBaseUrl == trimmed) {
      return;
    }

    settings.apiBaseUrl = trimmed;
    _settingsChanged();
    scheduleMetadataRefresh();
  }

  void setPlatform(ApiPlatform platform) {
    final previous = settings.platform;
    if (previous == platform) {
      return;
    }

    // A URL that was just the previous platform's default follows the platform switch.
    if (settings.apiBaseUrl.isNotEmpty && settings.apiBaseUrl.toLowerCase() == previous.defaultBaseUrl.toLowerCase()) {
      settings.apiBaseUrl = platform.defaultBaseUrl;
    }

    settings.platform = platform;
    samplerOptions = OptionLists.createOptionList(
      OptionLists.samplerDefaults(platform),
      null,
      OptionLists.defaultSampler(platform),
    );
    schedulerOptions = OptionLists.createOptionList(
      OptionLists.schedulerDefaults(platform),
      null,
      OptionLists.defaultScheduler(platform),
    );
    hiresUpscalerOptions = OptionLists.createOptionList(
      OptionLists.hiresUpscalerDefaults(platform),
      settings.hiresUpscaler,
      OptionLists.defaultHiresUpscaler(platform),
    );
    _resolveSelectedOptions();
    if (settings.generationMode.isNotEmpty) {
      settings.generationMode = GenerationModes.normalizeForPlatform(platform, settings.generationMode);
    }

    _settingsChanged();
    scheduleMetadataRefresh();
  }

  void setCheckpoint(String name) => edit((settings) => settings.checkpointModel = name.trim());

  void setLoras(List<LoraSelection> loras, {String? comfyLoaderType}) => edit((settings) {
        settings.selectedLoras = LoraSelection.normalize(loras);
        if (comfyLoaderType != null) {
          settings.comfyLoraLoaderType = ComfyLoraLoaderTypes.normalize(comfyLoaderType);
        }
      });

  void rename(String newName) {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == metadata.name) {
      return;
    }

    metadata.name = trimmed;
    notifyListeners();
    env.projectChanged(this);
    scheduleSave();
  }

  int get generateRepeatCount => _generateRepeatCount;
  set generateRepeatCount(int value) {
    final normalized = value.clamp(1, 99);
    if (_generateRepeatCount != normalized) {
      _generateRepeatCount = normalized;
      notifyListeners();
    }
  }

  void _settingsChanged() {
    notifyListeners();
    scheduleSave();
  }

  void _initializeOptions() {
    final platform = settings.platform;
    samplerOptions = OptionLists.createOptionList(
      OptionLists.samplerDefaults(platform),
      settings.samplerName,
      OptionLists.defaultSampler(platform),
    );
    schedulerOptions = OptionLists.createOptionList(
      OptionLists.schedulerDefaults(platform),
      settings.scheduler,
      OptionLists.defaultScheduler(platform),
    );
    hiresUpscalerOptions = OptionLists.createOptionList(
      OptionLists.hiresUpscalerDefaults(platform),
      settings.hiresUpscaler,
      OptionLists.defaultHiresUpscaler(platform),
    );
    _resolveSelectedOptions();
  }

  void _resolveSelectedOptions() {
    final platform = settings.platform;
    settings.samplerName =
        OptionLists.resolveOption(settings.samplerName, samplerOptions, OptionLists.defaultSampler(platform));
    settings.scheduler =
        OptionLists.resolveOption(settings.scheduler, schedulerOptions, OptionLists.defaultScheduler(platform));
    settings.hiresUpscaler = platform.isComfyUi
        ? ComfyWorkflow.resolveLatentUpscaleMethod(settings.hiresUpscaler, hiresUpscalerOptions)
        : OptionLists.resolveOption(
            settings.hiresUpscaler,
            hiresUpscalerOptions,
            OptionLists.defaultHiresUpscaler(platform),
          );
  }

  // ---------------------------------------------------------------------------------------------
  // Server metadata
  // ---------------------------------------------------------------------------------------------

  /// Called when the project becomes visible: starts listening for metadata and checks the server.
  void activate() {
    if (_active || _removed) {
      return;
    }

    _active = true;
    _comfyCacheSubscription ??= env.comfyCache.changes.listen(_onComfyCacheChanged);
    scheduleMetadataRefresh(immediate: true);
  }

  void deactivate() {
    _active = false;
    _metadataTimer?.cancel();
  }

  /// The app-wide URL or defaults changed.
  void preferencesChanged() {
    notifyListeners();
    if (_active && settings.apiBaseUrl.trim().isEmpty) {
      scheduleMetadataRefresh();
    }
  }

  void scheduleMetadataRefresh({bool immediate = false}) {
    _metadataTimer?.cancel();
    _metadataRefreshVersion++;
    if (!_active || _removed) {
      return;
    }

    final baseUrl = resolvedApiBaseUrl;
    if (settings.platform.isComfyUi) {
      final cached = env.comfyCache.tryGet(baseUrl);
      if (cached != null) {
        _applyComfyMetadata(cached);
      } else {
        _applyFallbackOptions();
      }

      isComfyMetadataLoading = env.comfyCache.isLoading(baseUrl);
    } else {
      isComfyMetadataLoading = false;
      final cached = env.webUiCache.tryGet(baseUrl);
      if (cached != null) {
        _applyWebUiMetadata(cached.samplers, cached.schedulers, cached.upscalers);
      }
    }

    serverStatus = ServerStatus.checking;
    notifyListeners();
    _metadataTimer = Timer(immediate ? Duration.zero : metadataRefreshDelay, () => unawaited(_refreshMetadata()));
  }

  Future<void> refreshServer() async {
    scheduleMetadataRefresh(immediate: true);
  }

  Future<void> _refreshMetadata() async {
    final version = _metadataRefreshVersion;
    final baseUrl = resolvedApiBaseUrl;
    final platform = settings.platform;
    final client = _ensureClient();
    final cancellation = CancellationSource(timeout: metadataRequestTimeout);
    try {
      final check = await client.checkServer(baseUrl, platform, cancellation.token);
      if (version != _metadataRefreshVersion) {
        return;
      }

      serverStatus = check.ok ? ServerStatus.online : ServerStatus.offline;
      serverMessage = check.message;
      notifyListeners();
      if (!check.ok) {
        return;
      }

      if (platform.isComfyUi) {
        isComfyMetadataLoading = true;
        notifyListeners();
        final metadata = await env.comfyCache.ensureCached(
          baseUrl,
          () => client.tryGetComfyMetadata(baseUrl, cancellation.token),
        );
        if (version != _metadataRefreshVersion) {
          return;
        }

        if (metadata != null) {
          _applyComfyMetadata(metadata);
        }
      } else if (env.webUiCache.tryGet(baseUrl) == null) {
        final results = await Future.wait([
          client.getSamplerNames(baseUrl, cancellation.token),
          client.getSchedulerNames(baseUrl, cancellation.token).catchError((Object _) => const <String>[]),
          client.getUpscalerNames(baseUrl, cancellation.token).catchError((Object _) => const <String>[]),
        ]);
        if (version != _metadataRefreshVersion) {
          return;
        }

        env.webUiCache.store(baseUrl, results[0], results[1], results[2]);
        _applyWebUiMetadata(results[0], results[1], results[2]);
      }
    } on OperationCanceledException {
      if (version == _metadataRefreshVersion) {
        serverStatus = ServerStatus.offline;
        serverMessage = 'Timed out while contacting ${EndpointDescription.of(baseUrl)}.';
      }
    } catch (error) {
      if (version == _metadataRefreshVersion) {
        serverStatus = ServerStatus.offline;
        serverMessage = SdClient.describeError(error);
      }
    } finally {
      cancellation.dispose();
      if (version == _metadataRefreshVersion) {
        isComfyMetadataLoading = platform.isComfyUi && env.comfyCache.isLoading(baseUrl);
        notifyListeners();
      }
    }
  }

  void _onComfyCacheChanged(String key) {
    if (!_active || !settings.platform.isComfyUi || key != ComfyMetadataCache.normalize(resolvedApiBaseUrl)) {
      return;
    }

    final metadata = env.comfyCache.tryGet(resolvedApiBaseUrl);
    if (metadata != null) {
      _applyComfyMetadata(metadata);
    }

    isComfyMetadataLoading = env.comfyCache.isLoading(resolvedApiBaseUrl);
    notifyListeners();
  }

  void _applyFallbackOptions() {
    final platform = settings.platform;
    samplerOptions = OptionLists.createOptionList(
      OptionLists.samplerDefaults(platform),
      settings.samplerName,
      OptionLists.defaultSampler(platform),
    );
    schedulerOptions = OptionLists.createOptionList(
      OptionLists.schedulerDefaults(platform),
      settings.scheduler,
      OptionLists.defaultScheduler(platform),
    );
    hiresUpscalerOptions = OptionLists.createOptionList(
      OptionLists.hiresUpscalerDefaults(platform),
      settings.hiresUpscaler,
      OptionLists.defaultHiresUpscaler(platform),
    );
    _resolveSelectedOptions();
  }

  void _applyComfyMetadata(ComfyObjectInfoMetadata metadata) {
    if (!settings.platform.isComfyUi) {
      return;
    }

    const platform = ApiPlatform.comfyUi;
    samplerOptions = OptionLists.createOptionList(
      metadata.samplerNames.isNotEmpty ? metadata.samplerNames : OptionLists.samplerDefaults(platform),
      settings.samplerName,
      OptionLists.defaultSampler(platform),
    );
    schedulerOptions = OptionLists.createOptionList(
      metadata.schedulerNames.isNotEmpty ? metadata.schedulerNames : OptionLists.schedulerDefaults(platform),
      settings.scheduler,
      OptionLists.defaultScheduler(platform),
    );
    hiresUpscalerOptions = OptionLists.createOptionList(
      metadata.latentUpscaleMethods.isNotEmpty
          ? metadata.latentUpscaleMethods
          : OptionLists.hiresUpscalerDefaults(platform),
      settings.hiresUpscaler,
      OptionLists.defaultHiresUpscaler(platform),
    );
    _resolveSelectedOptions();
    settings.comfyLoraLoaderType =
        ComfyWorkflow.resolveLoraLoaderType(settings.comfyLoraLoaderType, metadata.availableLoraLoaderTypes);
    notifyListeners();
  }

  void _applyWebUiMetadata(List<String> samplers, List<String> schedulers, List<String> upscalers) {
    if (!settings.platform.isWebUi) {
      return;
    }

    const platform = ApiPlatform.webUi;
    samplerOptions = OptionLists.createOptionList(
      samplers.isNotEmpty ? samplers : OptionLists.samplerDefaults(platform),
      settings.samplerName,
      OptionLists.defaultSampler(platform),
    );
    schedulerOptions = OptionLists.createOptionList(
      schedulers.isNotEmpty ? schedulers : OptionLists.schedulerDefaults(platform),
      settings.scheduler,
      OptionLists.defaultScheduler(platform),
    );
    hiresUpscalerOptions = OptionLists.createOptionList(
      upscalers.isNotEmpty ? upscalers : OptionLists.hiresUpscalerDefaults(platform),
      settings.hiresUpscaler,
      OptionLists.defaultHiresUpscaler(platform),
    );
    _resolveSelectedOptions();
    notifyListeners();
  }

  /// Checkpoints reported by the server, sorted, with the saved choice kept even when missing.
  Future<List<String>> fetchCheckpoints() async {
    final baseUrl = resolvedApiBaseUrl;
    final client = _ensureClient();
    final cancellation = CancellationSource(timeout: metadataRequestTimeout);
    try {
      List<String> names;
      if (settings.platform.isComfyUi) {
        final metadata = await client.getComfyMetadata(baseUrl, cancellation.token);
        env.comfyCache.store(baseUrl, metadata);
        names = metadata.checkpointNames;
      } else {
        names = await client.getCheckpointNames(baseUrl, cancellation.token);
      }

      final seen = <String>{};
      final sorted = [
        for (final name in names)
          if (name.trim().isNotEmpty && seen.add(name.toLowerCase())) name,
      ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final current = settings.checkpointModel.trim();
      if (current.isNotEmpty && !seen.contains(current.toLowerCase())) {
        sorted.insert(0, current);
      }

      return sorted;
    } on OperationCanceledException {
      throw ApiException('Timed out while loading checkpoints from ${EndpointDescription.of(baseUrl)}.');
    } finally {
      cancellation.dispose();
    }
  }

  Future<LoraCatalog> fetchLoras() async {
    final baseUrl = resolvedApiBaseUrl;
    final client = _ensureClient();
    final cancellation = CancellationSource(timeout: metadataRequestTimeout);
    try {
      if (settings.platform.isComfyUi) {
        final metadata = await client.getComfyMetadata(baseUrl, cancellation.token);
        env.comfyCache.store(baseUrl, metadata);
        return LoraCatalog(names: metadata.loraNames, loaderTypes: metadata.availableLoraLoaderTypes);
      }

      final names = await client.getLoraNames(baseUrl, cancellation.token);
      return LoraCatalog(names: names, loaderTypes: const [ComfyLoraLoaderTypes.loraLoader]);
    } on OperationCanceledException {
      throw ApiException('Timed out while loading LoRAs from ${EndpointDescription.of(baseUrl)}.');
    } finally {
      cancellation.dispose();
    }
  }

  SdClient _ensureClient() => _client ??= env.createClient();

  // ---------------------------------------------------------------------------------------------
  // Cells
  // ---------------------------------------------------------------------------------------------

  int get selectedCount => _cells.where((cell) => cell.isSelected).length;

  /// true when every cell is selected, false when none, null otherwise.
  bool? get selectAllState {
    final selected = selectedCount;
    if (selected == 0) {
      return false;
    }

    return selected == _cells.length ? true : null;
  }

  String get cellSelectionSummary {
    final selected = selectedCount;
    final count = selected > 0 ? selected : _cells.length;
    final noun = count == 1 ? 'cell' : 'cells';
    return selected > 0 ? '$count $noun selected' : '$count $noun';
  }

  /// Cells a plain "Generate" works on: the selection, or every cell when nothing is selected.
  List<CellModel> get generationTargets {
    final selected = _cells.where((cell) => cell.isSelected).toList();
    return selected.isEmpty ? [..._cells] : selected;
  }

  void setAllSelected(bool selected) {
    for (final cell in _cells) {
      cell.onSelectionChanged = null;
      cell.isSelected = selected;
      cell.onSelectionChanged = notifyListeners;
    }

    notifyListeners();
  }

  CellModel addCell({String prompt = ''}) {
    final cell = CellModel(id: newId(), order: _cells.length, name: 'Cell ${_cells.length + 1}', prompt: prompt);
    _attach(cell);
    _cellsChanged();
    return cell;
  }

  CellModel copyCell(CellModel source) {
    final cell = CellModel(
      id: newId(),
      order: _cells.length,
      name: '${source.displayName} Copy',
      prompt: source.prompt,
      overrideSteps: source.overrideSteps,
      overrideCfgScale: source.overrideCfgScale,
      overrideWidth: source.overrideWidth,
      overrideHeight: source.overrideHeight,
      overrideNegativePrompt: source.overrideNegativePrompt,
    );
    final index = _cells.indexOf(source);
    _attach(cell, index: index < 0 ? null : index + 1);
    _cellsChanged();
    return cell;
  }

  void removeCells(Iterable<CellModel> cells) {
    final targets = cells.toSet();
    if (targets.isEmpty) {
      return;
    }

    for (final cell in targets) {
      if (_cells.remove(cell)) {
        cell.onEdited = null;
        cell.onSelectionChanged = null;
      }
    }

    _cellsChanged();
  }

  void moveCell(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _cells.length) {
      return;
    }

    final target = newIndex.clamp(0, _cells.length - 1);
    if (target == oldIndex) {
      return;
    }

    final cell = _cells.removeAt(oldIndex);
    _cells.insert(target, cell);
    _cellsChanged();
  }

  CellModel? cellById(String cellId) {
    for (final cell in _cells) {
      if (cell.id == cellId) {
        return cell;
      }
    }

    return null;
  }

  void _attach(CellModel cell, {int? index}) {
    cell.onEdited = scheduleSave;
    cell.onSelectionChanged = notifyListeners;
    if (index == null || index >= _cells.length) {
      _cells.add(cell);
    } else {
      _cells.insert(index, cell);
    }
  }

  void _cellsChanged() {
    _reindex();
    notifyListeners();
    scheduleSave();
  }

  void _reindex() {
    for (var index = 0; index < _cells.length; index++) {
      _cells[index].order = index;
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Images
  // ---------------------------------------------------------------------------------------------

  String cellFolder(CellModel cell) => env.paths.cellFolder(id, cell.id);

  /// Images of a cell, newest first.
  Future<List<CellImage>> listImages(CellModel cell) async {
    final folder = Directory(cellFolder(cell));
    if (!await folder.exists()) {
      return [];
    }

    final images = <CellImage>[];
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is File && ImageSignature.supportedExtensions.contains(p.extension(entity.path).toLowerCase())) {
        images.add(CellImage(entity.path, ImageTimestamps.resolve(entity.path)));
      }
    }

    images.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime != 0 ? byTime : b.path.toLowerCase().compareTo(a.path.toLowerCase());
    });
    return images;
  }

  void setRepresentativeImage(CellModel cell, String? filePath) {
    cell.representativeImagePath = filePath != null && File(filePath).existsSync() ? filePath : null;
    cell.markImagesChanged();
  }

  Future<void> deleteImages(CellModel cell, Iterable<String> filePaths) async {
    final folder = p.normalize(cellFolder(cell));
    for (final filePath in filePaths) {
      // Only files inside the cell folder can be deleted from here.
      if (!p.isWithin(folder, p.normalize(filePath))) {
        continue;
      }

      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    }

    await refreshCellImageReferences(cell);
  }

  /// Re-points the cell at its newest image and drops a representative image that no longer exists.
  Future<void> refreshCellImageReferences(CellModel cell) async {
    final images = await listImages(cell);
    final newest = images.isEmpty ? null : images.first.path;
    if (cell.lastImagePath != newest) {
      cell.lastImagePath = newest;
    }

    final representative = cell.representativeImagePath;
    if (representative != null && !File(representative).existsSync()) {
      cell.representativeImagePath = null;
    }

    cell.markImagesChanged();
  }

  // ---------------------------------------------------------------------------------------------
  // Generation queue
  // ---------------------------------------------------------------------------------------------

  bool get canGenerate => _cells.isNotEmpty && !_removed;

  /// Queues the selected cells (or all cells) for [generateRepeatCount] round-robin passes.
  GenerationJob? generate({List<CellModel>? cells, int? repeatCount}) {
    final targets = cells ?? generationTargets;
    return _queue(targets, repeatCount ?? _generateRepeatCount);
  }

  GenerationJob? regenerate(CellModel cell) => _queue([cell], 1);

  GenerationJob? _queue(List<CellModel> targets, int repeatCount) {
    if (targets.isEmpty || _removed) {
      return null;
    }

    // Queued jobs work on a snapshot of the cells, so editing a prompt after pressing Generate
    // does not change work that is already waiting in the queue.
    final context = createContext(targets.map((cell) => cell.snapshot()).toList(), repeatCount);
    if (context.apiBaseUrl.trim().isEmpty) {
      env.messenger.warning('Set API Base URL first.');
      return null;
    }

    final job = GenerationJob.create(_nextJobSequence++, context);
    generation.pending.add(job);
    _refreshQueuedStatuses();
    generation.changed();
    env.projectChanged(this);
    _ensureQueueProcessor();
    return job;
  }

  GenerationContext createContext(List<CellSnapshot> targets, int repeatCount) {
    final prefs = env.preferences;
    final platform = settings.platform;
    return GenerationContext(
      projectId: id,
      projectName: name,
      apiBaseUrl: resolvedApiBaseUrl,
      platform: platform,
      timeout: Duration(seconds: effectiveTimeoutSeconds),
      generationMode: effectiveGenerationMode,
      clipSkip: effectiveClipSkip,
      globalCommonPrompt: settings.overrideGlobalCommonPrompt ? settings.globalCommonPromptOverride : prefs.globalCommonPrompt,
      commonPrompt: settings.commonPrompt,
      globalNegativePrompt:
          settings.overrideGlobalNegativePrompt ? settings.globalNegativePromptOverride : prefs.globalNegativePrompt,
      negativePrompt: settings.negativePrompt,
      steps: settings.steps < 1 ? 1 : settings.steps,
      cfgScale: settings.cfgScale < 1 ? 1 : settings.cfgScale,
      width: settings.width < 64 ? 64 : settings.width,
      height: settings.height < 64 ? 64 : settings.height,
      samplerName: settings.samplerName,
      scheduler: settings.scheduler,
      checkpointModel: settings.checkpointModel,
      selectedLoras: LoraSelection.normalize(settings.selectedLoras),
      comfyLoraLoaderType: ComfyLoraLoaderTypes.normalize(settings.comfyLoraLoaderType),
      seed: settings.seed < -1 ? -1 : settings.seed,
      enableHiresFix: settings.enableHiresFix,
      hiresScale: settings.hiresScale < 1 ? 1 : settings.hiresScale,
      hiresUpscaler: platform.isComfyUi
          ? ComfyWorkflow.resolveLatentUpscaleMethod(settings.hiresUpscaler, hiresUpscalerOptions)
          : OptionLists.resolveOption(
              settings.hiresUpscaler,
              hiresUpscalerOptions,
              OptionLists.defaultHiresUpscaler(platform),
            ),
      hiresSteps: settings.hiresSteps < 0 ? 0 : settings.hiresSteps,
      hiresDenoisingStrength: settings.hiresDenoisingStrength.clamp(0.0, 1.0).toDouble(),
      hiresResizeWidth: settings.hiresResizeWidth < 0 ? 0 : settings.hiresResizeWidth,
      hiresResizeHeight: settings.hiresResizeHeight < 0 ? 0 : settings.hiresResizeHeight,
      pollingRecoveryGraceSeconds: prefs.pollingRecoveryGraceSeconds,
      repeatCount: repeatCount < 1 ? 1 : repeatCount,
      targets: GenerationContext.roundRobin(targets, repeatCount),
    );
  }

  void removeQueuedJob(GenerationJob job) {
    if (generation.pending.remove(job)) {
      _refreshQueuedStatuses();
      generation.changed();
      env.projectChanged(this);
    }
  }

  void clearQueuedJobs() {
    if (generation.pending.isEmpty) {
      return;
    }

    generation.pending.clear();
    generation.changed();
    env.projectChanged(this);
  }

  void moveQueuedJob(int oldIndex, int newIndex) {
    final pending = generation.pending;
    if (oldIndex < 0 || oldIndex >= pending.length) {
      return;
    }

    final job = pending.removeAt(oldIndex);
    pending.insert(newIndex.clamp(0, pending.length), job);
    _refreshQueuedStatuses();
    generation.changed();
  }

  /// Two-stage interrupt: the first call stops after the image that was already requested, the second
  /// force-stops the current job (the queue then continues with the next job).
  Future<void> interrupt() async {
    final cancellation = _jobCancellation;
    final job = generation.current;
    if (cancellation == null || job == null || !generation.isGenerating) {
      return;
    }

    if (!generation.stopAfterCurrentImageRequested) {
      generation.stopAfterCurrentImageRequested = true;
      generation.forceInterruptRequested = false;
      job.status = 'Interrupting after current request... (${job.progressText})';
      generation.changed();
      env.messenger.info(
        'Will stop after the last requested image in $name. Interrupt again to force stop immediately.',
      );
      return;
    }

    if (generation.forceInterruptRequested) {
      return;
    }

    final platform = job.context.platform;
    generation.forceInterruptRequested = true;
    job.status = 'Force stopping current job... (${job.progressText})';
    if (platform.isWebUi) {
      _waitForWebUiIdle = true;
    }

    generation.changed();

    String? failure;
    if (platform.isWebUi) {
      // ComfyUI prompts and Agent Scheduler tasks are cleaned up by the generation loop once it observes
      // the cancellation; WebUI needs an explicit interrupt to stop the image that is being sampled.
      final timeout = CancellationSource(timeout: GenerationRunner.interruptRequestTimeout);
      try {
        await _ensureClient().interrupt(job.context.apiBaseUrl, timeout.token);
      } catch (error) {
        failure = SdClient.describeError(error);
      } finally {
        timeout.dispose();
      }
    }

    cancellation.cancel();
    if (failure == null) {
      env.messenger.info('Force interrupt requested for $name.');
    } else {
      env.messenger.warning('Force stop requested for $name, but the WebUI interrupt API failed: $failure');
    }
  }

  void _refreshQueuedStatuses() {
    for (var index = 0; index < generation.pending.length; index++) {
      generation.pending[index].status = 'Queued (${index + 1})';
    }
  }

  void _ensureQueueProcessor() {
    if (_queueProcessor != null) {
      return;
    }

    _queueProcessor = _processQueue().whenComplete(() => _queueProcessor = null);
  }

  Future<void> _processQueue() async {
    while (generation.pending.isNotEmpty && !_removed) {
      final job = generation.pending.removeAt(0);
      _refreshQueuedStatuses();
      generation.current = job;
      job.status = 'Starting... (${job.progressText})';
      generation.changed();
      env.projectChanged(this);
      try {
        await _runJob(job);
      } finally {
        generation.current = null;
        generation.changed();
        env.projectChanged(this);
      }
    }
  }

  Future<void> _runJob(GenerationJob job) async {
    final cancellation = CancellationSource();
    _jobCancellation = cancellation;
    generation
      ..stopAfterCurrentImageRequested = false
      ..forceInterruptRequested = false
      ..isGenerating = true
      ..statusText = job.status;
    generation.changed();

    try {
      _runner ??= GenerationRunner(this, _ensureClient());
      await _runner!.run(job.context, cancellation.token);
    } on OperationCanceledException {
      // Interrupted before any image request started (for example while waiting for WebUI to go idle).
      report(
        generation.forceInterruptRequested ? 'Generation force-stopped in $name.' : 'Generation interrupted in $name.',
        MessageSeverity.info,
      );
    } catch (error, stackTrace) {
      // The generation loops report their own request failures; this keeps the queue alive.
      AppLog.write('Generation job in $name', error, stackTrace);
      report('Generation failed in $name: ${SdClient.describeError(error)}', MessageSeverity.error);
    } finally {
      cancellation.dispose();
      _jobCancellation = null;
      generation
        ..stopAfterCurrentImageRequested = false
        ..forceInterruptRequested = false
        ..isGenerating = false
        ..statusText = 'Ready'
        ..preview = null
        ..previewCellId = null;
      generation.changed();
    }
  }

  // GenerationHost ---------------------------------------------------------------------------------

  @override
  bool get stopAfterCurrentImageRequested => generation.stopAfterCurrentImageRequested;

  @override
  bool get forceInterruptRequested => generation.forceInterruptRequested;

  @override
  bool get livePreviewEnabled => env.preferences.livePreviewEnabled;

  @override
  bool get waitForWebUiIdle => _waitForWebUiIdle;

  @override
  set waitForWebUiIdle(bool value) => _waitForWebUiIdle = value;

  @override
  bool isCellAlive(String cellId) => !_removed && cellById(cellId) != null;

  @override
  void setCellBusy(String cellId, bool busy) {
    cellById(cellId)?.isBusy = busy;
    if (!busy && generation.previewCellId == cellId) {
      generation
        ..preview = null
        ..previewCellId = null;
      generation.changed();
    }
  }

  @override
  void setCellPreview(String cellId, Uint8List? preview, double? progress) {
    cellById(cellId)?.setLivePreview(preview, progress);
    if (preview != null) {
      generation
        ..preview = preview
        ..previewCellId = cellId;
      generation.changed();
    }
  }

  @override
  void setStatus(String text, {double? imageProgress}) {
    final job = generation.current;
    if (job != null && !generation.isInterrupting) {
      job.status = text;
    }

    job?.imageProgress = imageProgress;
    generation.statusText = text;
    generation.changed();
  }

  @override
  void markRequestCompleted() {
    final job = generation.current;
    if (job == null) {
      return;
    }

    job
      ..completedImages = (job.completedImages + 1).clamp(0, job.totalImages)
      ..imageProgress = null;
    generation.changed();
  }

  @override
  void report(String message, MessageSeverity severity) => env.messenger.show(message, severity);

  @override
  Future<void> saveImage(CellSnapshot cell, Uint8List bytes) async {
    if (_removed) {
      // The project was removed while this image was being generated.
      return;
    }

    final live = cellById(cell.id);
    if (live == null) {
      report('Discarded the image for ${cell.displayName} because the cell no longer exists.', MessageSeverity.warning);
      return;
    }

    final folder = env.paths.cellFolder(id, cell.id);
    final fileName = FileIo.uniqueFileName(
      folder,
      ImageTimestamps.fileBaseName(DateTime.now()),
      ImageSignature.detectExtension(bytes),
    );
    final filePath = p.join(folder, fileName);
    // Written to a temporary file first so an interrupted write never leaves a truncated image behind.
    await FileIo.writeBytesAtomic(filePath, bytes);
    live.lastImagePath = filePath;
    live.markImagesChanged();
  }

  @override
  void storeComfyMetadata(String baseUrl, ComfyObjectInfoMetadata metadata) => env.comfyCache.store(baseUrl, metadata);

  // ---------------------------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------------------------

  void scheduleSave() {
    if (_removed) {
      return;
    }

    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(autosaveDelay, () => unawaited(saveNow()));
  }

  bool get hasUnsavedChanges => _dirty;

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    if (!_dirty || _removed) {
      return;
    }

    _dirty = false;
    final data = snapshot(touchUpdatedAt: true);
    try {
      final written = await env.store.save(data);
      if (written) {
        metadata.updatedAt = data.metadata.updatedAt;
        env.projectChanged(this);
      }
    } catch (error, stackTrace) {
      // Keep the changes marked so the next autosave retries them.
      AppLog.write('Saving project $id', error, stackTrace);
      env.messenger.error('Failed to save project "$name": ${SdClient.describeError(error)} '
          'The changes are kept and saving will be retried.');
      _dirty = true;
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(seconds: 5), () => unawaited(saveNow()));
    }
  }

  ProjectData snapshot({bool touchUpdatedAt = false}) {
    final metadataCopy = metadata.copy();
    if (touchUpdatedAt) {
      metadataCopy.updatedAt = DateTime.now();
    }

    final settingsCopy = settings.copy();
    if (settingsCopy.platform.isComfyUi) {
      settingsCopy.generationMode = GenerationModes.standard;
    }

    return ProjectData(
      metadata: metadataCopy,
      settings: settingsCopy,
      cells: _cells.map((cell) => cell.toData(projectFolder)).toList(),
    );
  }

  /// Stops all work of a project that is being removed. Images that are still arriving are discarded.
  void markRemoved() {
    _removed = true;
    _active = false;
    _saveTimer?.cancel();
    _metadataTimer?.cancel();
    generation.pending.clear();
    _jobCancellation?.cancel();
    generation.changed();
  }

  @override
  void dispose() {
    markRemoved();
    unawaited(_comfyCacheSubscription?.cancel());
    // A job that is still winding down keeps using its client; it is closed once idle.
    final client = _client;
    if (client != null) {
      if (_queueProcessor == null) {
        client.close();
      } else {
        unawaited(_queueProcessor!.whenComplete(client.close));
      }
    }

    super.dispose();
  }
}

/// Formats a base URL for messages without leaking credentials.
abstract final class EndpointDescription {
  static String of(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || uri.host.isEmpty) {
      return baseUrl.trim();
    }

    return uri.replace(userInfo: '').toString();
  }
}
