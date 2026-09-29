import 'dart:io';

import 'package:path/path.dart' as p;

/// Locations of everything the app stores on disk.
///
/// ```
/// <root>/preferences.json
/// <root>/comfy-metadata-cache.json
/// <root>/projects/<project-id>/project.json
/// <root>/projects/<project-id>/cells/<cell-id>/<yyyyMMdd_HHmmssfff>.png
/// <root>/prompt-autocomplete/{danbooru,extra-quality-tags,custom-tags}.csv
/// <root>/logs/multiplex.log
/// ```
class AppPaths {
  AppPaths(this.root);

  final String root;

  String get projectsRoot => p.join(root, 'projects');
  String get preferencesFile => p.join(root, 'preferences.json');
  String get comfyMetadataCacheFile => p.join(root, 'comfy-metadata-cache.json');
  String get autocompleteRoot => p.join(root, 'prompt-autocomplete');
  String get autocompleteDanbooruFile => p.join(autocompleteRoot, 'danbooru.csv');
  String get autocompleteExtraQualityFile => p.join(autocompleteRoot, 'extra-quality-tags.csv');
  String get autocompleteCustomFile => p.join(autocompleteRoot, 'custom-tags.csv');
  String get logFile => p.join(root, 'logs', 'multiplex.log');
  String get tempRoot => p.join(root, 'tmp');

  String projectFolder(String projectId) => p.join(projectsRoot, projectId);
  String projectFile(String projectId) => p.join(projectFolder(projectId), 'project.json');
  String cellFolder(String projectId, String cellId) => p.join(projectFolder(projectId), 'cells', cellId);

  Future<void> ensureCreated() async {
    await Directory(projectsRoot).create(recursive: true);
    await Directory(autocompleteRoot).create(recursive: true);
  }
}
