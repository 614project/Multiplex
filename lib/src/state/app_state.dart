import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api/sd_client.dart';
import '../models/app_preferences.dart';
import '../services/app_log.dart';
import '../services/app_paths.dart';
import '../services/autocomplete_service.dart';
import '../services/comfy_metadata_cache.dart';
import '../services/preferences_store.dart';
import '../services/project_store.dart';
import '../services/project_transfer.dart';
import 'app_messenger.dart';
import 'project_session.dart';

/// Root state: preferences, the project list, the selected project and shared services.
class AppState extends ChangeNotifier implements SessionEnvironment {
  AppState({required this.paths, http.Client Function()? httpClientFactory})
      : store = ProjectStore(paths),
        _preferencesStore = PreferencesStore(paths.preferencesFile),
        comfyCache = ComfyMetadataCache(paths.comfyMetadataCacheFile),
        autocomplete = AutocompleteService(paths),
        _httpClientFactory = httpClientFactory;

  @override
  final AppPaths paths;
  @override
  final ProjectStore store;
  @override
  final ComfyMetadataCache comfyCache;
  @override
  final WebUiMetadataCache webUiCache = WebUiMetadataCache();
  @override
  final AppMessenger messenger = AppMessenger();
  final AutocompleteService autocomplete;
  final PreferencesStore _preferencesStore;
  final http.Client Function()? _httpClientFactory;

  @override
  AppPreferences preferences = AppPreferences();
  final List<ProjectSession> _projects = [];
  ProjectSession? _selected;
  bool _initialized = false;
  bool _busy = false;
  Timer? _preferencesSaveTimer;

  List<ProjectSession> get projects => List.unmodifiable(_projects);
  ProjectSession? get selected => _selected;
  bool get isInitialized => _initialized;
  bool get isBusy => _busy;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    await paths.ensureCreated();
    AppLog.configure(paths.logFile);
    try {
      preferences = await _preferencesStore.load();
    } catch (error, stackTrace) {
      // Broken app settings must not keep the projects from loading; defaults are used instead.
      AppLog.write('Loading app settings', error, stackTrace);
      messenger.warning('Failed to load app settings, so defaults are used: $error');
    }

    autocomplete.enabled = preferences.promptAutocompleteEnabled;
    await comfyCache.load();

    final unreadable = <String>[];
    final loaded = await store.loadAll(unreadableProjectIds: unreadable);
    for (final data in loaded) {
      _projects.add(ProjectSession(this, data));
    }

    if (unreadable.isNotEmpty) {
      messenger.warning(
        'Skipped ${unreadable.length} project(s) whose data could not be read. Details are in ${paths.logFile}.',
      );
    }

    if (_projects.isEmpty) {
      _projects.add(ProjectSession(this, await store.create(ProjectStore.defaultProjectName())));
    }

    final last = _projects.where((project) => project.id == preferences.lastProjectId).firstOrNull;
    _initialized = true;
    select(last ?? _projects.first);

    if (preferences.promptAutocompleteEnabled) {
      unawaited(autocomplete.warmUp(onFailure: messenger.warning));
    }
  }

  @override
  SdClient createClient() => SdClient(httpClient: _httpClientFactory?.call());

  @override
  void projectChanged(ProjectSession session) => notifyListeners();

  void select(ProjectSession? session) {
    if (session == null || identical(session, _selected) || !_projects.contains(session)) {
      return;
    }

    _selected?.deactivate();
    _selected = session;
    session.activate();
    if (preferences.lastProjectId != session.id) {
      updatePreferences((prefs) => prefs.lastProjectId = session.id);
    }

    notifyListeners();
  }

  /// Applies a preference change, notifies the UI and saves shortly after.
  void updatePreferences(void Function(AppPreferences prefs) change) {
    final previousGlobalUrl = preferences.globalApiBaseUrl;
    change(preferences);
    preferences.normalize();
    autocomplete.enabled = preferences.promptAutocompleteEnabled;
    if (preferences.promptAutocompleteEnabled && !autocomplete.isReady) {
      unawaited(autocomplete.warmUp(onFailure: messenger.warning));
    }

    if (previousGlobalUrl != preferences.globalApiBaseUrl) {
      for (final project in _projects) {
        project.preferencesChanged();
      }
    }

    notifyListeners();
    _preferencesSaveTimer?.cancel();
    _preferencesSaveTimer = Timer(const Duration(milliseconds: 600), () => unawaited(_savePreferences()));
  }

  Future<void> _savePreferences() async {
    _preferencesSaveTimer?.cancel();
    try {
      await _preferencesStore.save(preferences);
    } catch (error, stackTrace) {
      AppLog.write('Saving app settings', error, stackTrace);
      messenger.error('Failed to save app settings: $error');
    }
  }

  Future<T?> _runBusy<T>(Future<T> Function() action) async {
    if (_busy) {
      return null;
    }

    _busy = true;
    notifyListeners();
    try {
      return await action();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<ProjectSession?> createProject({String? name}) => _runBusy<ProjectSession?>(() async {
        try {
          final session = ProjectSession(this, await store.create(name ?? ProjectStore.defaultProjectName()));
          _projects.insert(0, session);
          select(session);
          return session;
        } catch (error, stackTrace) {
          AppLog.write('Creating project', error, stackTrace);
          messenger.error('Failed to create project: $error');
          return null;
        }
      });

  Future<ProjectSession?> cloneProject(ProjectSession source) => _runBusy<ProjectSession?>(() async {
        try {
          await source.saveNow();
          final session = ProjectSession(this, await store.clone(source.snapshot()));
          _projects.insert(0, session);
          select(session);
          messenger.success('Project cloned.');
          return session;
        } catch (error, stackTrace) {
          AppLog.write('Cloning project ${source.id}', error, stackTrace);
          messenger.error('Failed to clone project: $error');
          return null;
        }
      });

  Future<void> removeProject(ProjectSession session) async {
    if (session.generation.hasWork) {
      messenger.warning('Stop or clear the generation queue of "${session.name}" before removing it.');
      return;
    }

    await _runBusy(() async {
      final wasSelected = identical(session, _selected);
      try {
        await store.delete(session.id);
      } catch (error, stackTrace) {
        // The project is still on disk, so its changes must be saved again.
        store.abortRemoval(session.id);
        AppLog.write('Removing project ${session.id}', error, stackTrace);
        messenger.error('Failed to remove project: $error');
        return;
      }

      _projects.remove(session);
      if (wasSelected) {
        _selected = null;
      }

      session.dispose();
      if (_projects.isEmpty) {
        _projects.add(ProjectSession(this, await store.create(ProjectStore.defaultProjectName())));
      }

      if (wasSelected) {
        select(_projects.first);
      }

      messenger.info('Project removed.');
    });
  }

  /// Imports one or more projects from WebuiMultiflex/Multiplex JSON. Returns the number imported.
  Future<int> importProjects(String json) async {
    final result = await _runBusy(() async {
      try {
        final imported = ProjectTransfer.deserialize(json);
        final sessions = <ProjectSession>[];
        for (final project in imported) {
          final data = await store.create(project.name, settings: project.settings, cells: project.cells);
          sessions.add(ProjectSession(this, data));
        }

        _projects.insertAll(0, sessions);
        select(sessions.first);
        messenger.success(sessions.length == 1
            ? 'Project "${sessions.first.name}" imported.'
            : 'Imported ${sessions.length} projects.');
        return sessions.length;
      } catch (error, stackTrace) {
        AppLog.write('Importing projects', error, stackTrace);
        messenger.error('Failed to import project: ${error is FormatException ? error.message : error}');
        return 0;
      }
    });
    return result ?? 0;
  }

  Future<String> exportAllProjects() async {
    await flush();
    return ProjectTransfer.serializeProjects(_projects.map((project) => project.snapshot()));
  }

  /// Writes pending project and preference changes (called when the app is paused or closed).
  Future<void> flush() async {
    for (final project in _projects) {
      await project.saveNow();
    }

    if (_preferencesSaveTimer?.isActive ?? false) {
      await _savePreferences();
    }

    await store.flush();
  }

  @override
  void dispose() {
    _preferencesSaveTimer?.cancel();
    for (final project in _projects) {
      project.dispose();
    }

    autocomplete.dispose();
    unawaited(comfyCache.dispose());
    unawaited(messenger.dispose());
    super.dispose();
  }
}
