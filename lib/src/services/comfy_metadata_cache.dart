import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/sd_models.dart';
import 'app_log.dart';
import 'file_io.dart';

/// Address-based, time-bounded cache of ComfyUI `/object_info` lists, persisted across launches.
/// Projects that share an endpoint reuse the same metadata instead of fetching several megabytes again.
class ComfyMetadataCache {
  ComfyMetadataCache(this.filePath, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const lifetime = Duration(days: 7);

  final String filePath;
  final DateTime Function() _clock;
  final Map<String, _Entry> _entries = {};
  final Map<String, Future<ComfyObjectInfoMetadata?>> _inFlight = {};
  final StreamController<String> _changes = StreamController<String>.broadcast();
  Future<void> _persistChain = Future<void>.value();

  /// Emits the normalized base URL whose cache entry (or loading state) changed.
  Stream<String> get changes => _changes.stream;

  static String normalize(String? baseUrl) => (baseUrl ?? '').trim().toLowerCase();

  Future<void> load() async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return;
      }

      final json = jsonDecode(await file.readAsString());
      if (json is! List) {
        return;
      }

      final cutoff = _clock().subtract(lifetime);
      for (final item in json) {
        if (item is! Map) {
          continue;
        }

        final baseUrl = item['baseUrl'];
        final fetchedAt = DateTime.tryParse('${item['fetchedAtUtc']}');
        final metadata = ComfyObjectInfoMetadata.fromJson(item['metadata']);
        if (baseUrl is String && fetchedAt != null && metadata != null && fetchedAt.isAfter(cutoff)) {
          _entries[normalize(baseUrl)] = _Entry(baseUrl.trim(), fetchedAt, metadata);
        }
      }
    } catch (error, stackTrace) {
      AppLog.write('Loading ComfyUI metadata cache', error, stackTrace);
    }
  }

  ComfyObjectInfoMetadata? tryGet(String? baseUrl) {
    final key = normalize(baseUrl);
    final entry = _entries[key];
    if (entry == null) {
      return null;
    }

    if (_isExpired(entry)) {
      _entries.remove(key);
      _persist();
      return null;
    }

    return entry.metadata;
  }

  /// Replaces the entry with metadata that was just fetched elsewhere (for example by a generation job).
  void store(String? baseUrl, ComfyObjectInfoMetadata metadata) {
    final key = normalize(baseUrl);
    if (key.isEmpty) {
      return;
    }

    _entries[key] = _Entry(baseUrl!.trim(), _clock().toUtc(), metadata);
    _persist();
    _changes.add(key);
  }

  bool isLoading(String? baseUrl) => _inFlight.containsKey(normalize(baseUrl));

  /// Loads the metadata unless a fresh entry exists; concurrent callers share one request.
  Future<ComfyObjectInfoMetadata?> ensureCached(
    String? baseUrl,
    Future<ComfyObjectInfoMetadata?> Function() loader,
  ) {
    final key = normalize(baseUrl);
    if (key.isEmpty) {
      return Future.value();
    }

    final cached = tryGet(baseUrl);
    if (cached != null) {
      return Future.value(cached);
    }

    final inFlight = _inFlight[key];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _loadAndCache(key, baseUrl!.trim(), loader);
    _inFlight[key] = future;
    _changes.add(key);
    return future;
  }

  Future<ComfyObjectInfoMetadata?> _loadAndCache(
    String key,
    String baseUrl,
    Future<ComfyObjectInfoMetadata?> Function() loader,
  ) async {
    ComfyObjectInfoMetadata? metadata;
    try {
      metadata = await loader();
      if (metadata != null) {
        _entries[key] = _Entry(baseUrl, _clock().toUtc(), metadata);
        _persist();
      }
    } finally {
      unawaited(_inFlight.remove(key));
      _changes.add(key);
    }

    return metadata;
  }

  bool _isExpired(_Entry entry) => entry.fetchedAt.isBefore(_clock().subtract(lifetime));

  void _persist() {
    final snapshot = [
      for (final entry in _entries.values)
        {
          'baseUrl': entry.baseUrl,
          'fetchedAtUtc': entry.fetchedAt.toUtc().toIso8601String(),
          'metadata': entry.metadata.toJson(),
        },
    ];
    final json = jsonEncode(snapshot);
    _persistChain = _persistChain
        .then((_) => FileIo.writeStringAtomic(filePath, json))
        .catchError((Object error, StackTrace stackTrace) {
      AppLog.write('Saving ComfyUI metadata cache', error, stackTrace);
    });
  }

  Future<void> dispose() async {
    await _persistChain;
    await _changes.close();
  }
}

class _Entry {
  _Entry(this.baseUrl, this.fetchedAt, this.metadata);

  final String baseUrl;
  final DateTime fetchedAt;
  final ComfyObjectInfoMetadata metadata;
}
