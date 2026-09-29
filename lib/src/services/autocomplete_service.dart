import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_log.dart';
import 'app_paths.dart';

/// Tag suggestions for prompt fields, built from the shared Danbooru tag dataset plus an optional
/// user supplied CSV (`name,category,count,"alias1,alias2"`).
class AutocompleteService extends ChangeNotifier {
  AutocompleteService(this.paths, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static const minimumFragmentLength = 2;
  static const defaultMaxSuggestions = 8;
  static final Uri danbooruTagsUri = Uri.parse(
    'https://raw.githubusercontent.com/dreamscapeai/tagcomplete/main/tags/danbooru.csv',
  );
  static final Uri extraQualityTagsUri = Uri.parse(
    'https://raw.githubusercontent.com/dreamscapeai/tagcomplete/main/tags/extra-quality-tags.csv',
  );

  final AppPaths paths;
  final http.Client _http;
  Map<String, List<AutocompleteEntry>>? _buckets;
  Future<bool>? _warmup;
  bool enabled = true;
  bool _busy = false;
  int _entryCount = 0;

  bool get isReady => _buckets != null;
  bool get isBusy => _busy;
  int get entryCount => _entryCount;

  bool get hasLocalData =>
      File(paths.autocompleteDanbooruFile).existsSync() ||
      File(paths.autocompleteExtraQualityFile).existsSync() ||
      File(paths.autocompleteCustomFile).existsSync();

  bool get hasCustomData => File(paths.autocompleteCustomFile).existsSync();

  /// Loads (and on first use downloads) the tag data in the background.
  Future<bool> warmUp({void Function(String message)? onFailure}) {
    if (_buckets != null) {
      return Future.value(true);
    }

    return _warmup ??= _ensureReady(forceDownload: false, onFailure: onFailure).whenComplete(() => _warmup = null);
  }

  Future<bool> redownload({void Function(String message)? onFailure}) =>
      _ensureReady(forceDownload: true, onFailure: onFailure);

  Future<bool> importCustomCsv(List<int> bytes, {void Function(String message)? onFailure}) async {
    try {
      await Directory(paths.autocompleteRoot).create(recursive: true);
      final temporary = File('${paths.autocompleteCustomFile}.import');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(paths.autocompleteCustomFile);
      await _rebuild();
      return true;
    } catch (error, stackTrace) {
      AppLog.write('Importing autocomplete CSV', error, stackTrace);
      onFailure?.call('Prompt autocomplete CSV import failed: $error');
      return false;
    }
  }

  List<String> suggestionsFor(String fragment, {int maxResults = defaultMaxSuggestions}) {
    if (!enabled) {
      return const [];
    }

    final normalized = normalizeSearchKey(fragment);
    if (normalized.length < minimumFragmentLength) {
      return const [];
    }

    final buckets = _buckets;
    if (buckets == null) {
      if (hasLocalData) {
        unawaited(warmUp());
      }

      return const [];
    }

    final bucket = buckets[normalized.substring(0, 2)];
    if (bucket == null) {
      return const [];
    }

    final suggestions = <String>[];
    final seen = <String>{};
    for (final entry in bucket) {
      if (!entry.searchKey.startsWith(normalized) || !seen.add(entry.canonical.toLowerCase())) {
        continue;
      }

      suggestions.add(entry.canonical);
      if (suggestions.length >= maxResults) {
        break;
      }
    }

    return suggestions;
  }

  Future<bool> _ensureReady({required bool forceDownload, void Function(String message)? onFailure}) async {
    _setBusy(true);
    try {
      if (forceDownload || !hasLocalData) {
        await Directory(paths.autocompleteRoot).create(recursive: true);
        await _download(danbooruTagsUri, paths.autocompleteDanbooruFile);
        await _download(extraQualityTagsUri, paths.autocompleteExtraQualityFile);
        _buckets = null;
      }

      if (_buckets == null) {
        await _rebuild();
      }

      return true;
    } catch (error, stackTrace) {
      AppLog.write('Preparing prompt autocomplete data', error, stackTrace);
      onFailure?.call('Prompt autocomplete data download failed: $error');
      return false;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _download(Uri source, String destination) async {
    final response = await _http.get(source, headers: {'User-Agent': 'Multiplex/1.0'});
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode} while downloading ${source.pathSegments.last}');
    }

    final temporary = File('$destination.download');
    await temporary.writeAsBytes(response.bodyBytes, flush: true);
    await temporary.rename(destination);
  }

  Future<void> _rebuild() async {
    final sources = [
      (paths.autocompleteCustomFile, 0),
      (paths.autocompleteExtraQualityFile, 1),
      (paths.autocompleteDanbooruFile, 2),
    ];
    final buckets = await _buildInBackground(sources);
    _buckets = buckets;
    _entryCount = buckets.values.fold(0, (sum, bucket) => sum + bucket.length);
    notifyListeners();
  }

  void _setBusy(bool value) {
    if (_busy != value) {
      _busy = value;
      notifyListeners();
    }
  }

  // Static so the isolate closure cannot capture this (non-sendable) notifier.
  static Future<Map<String, List<AutocompleteEntry>>> _buildInBackground(List<(String, int)> sources) =>
      Isolate.run(() => buildBuckets(sources));

  /// Parses the CSV sources (path, priority) into two-character search buckets.
  static Map<String, List<AutocompleteEntry>> buildBuckets(List<(String, int)> sources) {
    final buckets = <String, List<AutocompleteEntry>>{};
    for (final (path, priority) in sources) {
      final file = File(path);
      if (!file.existsSync()) {
        continue;
      }

      for (final line in const LineSplitter().convert(file.readAsStringSync())) {
        final tag = parseTagLine(line);
        if (tag == null) {
          continue;
        }

        addEntry(buckets, tag.name, tag.name, tag.postCount, false, priority);
        for (final alias in tag.aliases) {
          addEntry(buckets, tag.name, alias, tag.postCount, true, priority);
        }
      }
    }

    for (final bucket in buckets.values) {
      bucket.sort(AutocompleteEntry.compare);
    }

    return buckets;
  }

  static void addEntry(
    Map<String, List<AutocompleteEntry>> buckets,
    String canonical,
    String searchText,
    int postCount,
    bool isAlias,
    int priority,
  ) {
    final key = normalizeSearchKey(searchText);
    if (canonical.trim().isEmpty || key.length < minimumFragmentLength) {
      return;
    }

    (buckets[key.substring(0, 2)] ??= []).add(
      AutocompleteEntry(canonical.trim(), key, postCount < 0 ? 0 : postCount, isAlias, priority),
    );
  }

  static ({String name, int postCount, List<String> aliases})? parseTagLine(String line) {
    if (line.trim().isEmpty) {
      return null;
    }

    final columns = splitCsvLine(line);
    final name = columns.first.trim();
    if (name.isEmpty) {
      return null;
    }

    final postCount = columns.length > 2 ? int.tryParse(columns[2].trim()) ?? 0 : 0;
    final aliases = <String>[];
    if (columns.length > 3) {
      final seen = <String>{name.toLowerCase()};
      for (final alias in columns[3].split(',')) {
        final trimmed = alias.trim();
        if (trimmed.isNotEmpty && seen.add(trimmed.toLowerCase())) {
          aliases.add(trimmed);
        }
      }
    }

    return (name: name, postCount: postCount, aliases: aliases);
  }

  static List<String> splitCsvLine(String line) {
    final columns = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;
    for (var index = 0; index < line.length; index++) {
      final character = line[index];
      if (character == '"') {
        if (inQuotes && index + 1 < line.length && line[index + 1] == '"') {
          buffer.write('"');
          index++;
        } else {
          inQuotes = !inQuotes;
        }

        continue;
      }

      if (character == ',' && !inQuotes) {
        columns.add(buffer.toString());
        buffer.clear();
        continue;
      }

      buffer.write(character);
    }

    columns.add(buffer.toString());
    return columns;
  }

  /// Lowercases and collapses whitespace/underscores to a single underscore.
  static String normalizeSearchKey(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    var pendingUnderscore = false;
    for (final rune in value.trim().runes) {
      final character = String.fromCharCode(rune);
      if (character == '_' || character.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          pendingUnderscore = true;
        }

        continue;
      }

      if (pendingUnderscore) {
        buffer.write('_');
        pendingUnderscore = false;
      }

      buffer.write(character.toLowerCase());
    }

    return buffer.toString();
  }

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}

class AutocompleteEntry {
  const AutocompleteEntry(this.canonical, this.searchKey, this.postCount, this.isAlias, this.priority);

  final String canonical;
  final String searchKey;
  final int postCount;
  final bool isAlias;
  final int priority;

  static int compare(AutocompleteEntry x, AutocompleteEntry y) {
    if (x.isAlias != y.isAlias) {
      return x.isAlias ? 1 : -1;
    }

    if (x.priority != y.priority) {
      return x.priority.compareTo(y.priority);
    }

    if (x.postCount != y.postCount) {
      return y.postCount.compareTo(x.postCount);
    }

    if (x.canonical.length != y.canonical.length) {
      return x.canonical.length.compareTo(y.canonical.length);
    }

    return x.canonical.toLowerCase().compareTo(y.canonical.toLowerCase());
  }
}

/// The comma-separated fragment being typed at the caret, and how to replace it.
class PromptFragment {
  const PromptFragment(this.start, this.length, this.text);

  final int start;
  final int length;
  final String text;

  /// Finds the fragment between the previous comma/newline and the caret, or null when it is too short.
  static PromptFragment? at(String text, int caret) {
    if (caret < 0 || caret > text.length) {
      return null;
    }

    var segmentStart = caret;
    while (segmentStart > 0) {
      final previous = text[segmentStart - 1];
      if (previous == ',' || previous == '\n' || previous == '\r') {
        break;
      }

      segmentStart--;
    }

    var replaceStart = segmentStart;
    while (replaceStart < caret && text[replaceStart].trim().isEmpty) {
      replaceStart++;
    }

    final length = caret - replaceStart;
    if (length <= 0) {
      return null;
    }

    final value = text.substring(replaceStart, caret).trim();
    if (value.length < AutocompleteService.minimumFragmentLength) {
      return null;
    }

    return PromptFragment(replaceStart, length, value);
  }

  /// Replaces the fragment with [suggestion] (underscores become spaces) and returns the new text and
  /// caret offset. With [appendSeparator] a ", " is added unless the text already continues with a comma.
  (String, int) apply(String text, String suggestion, {bool appendSeparator = false}) {
    final inserted = suggestion.replaceAll('_', ' ');
    final before = text.substring(0, start.clamp(0, text.length));
    final after = text.substring((start + length).clamp(0, text.length));
    final separator = appendSeparator && !after.trimLeft().startsWith(',') ? ', ' : '';
    final newText = '$before$inserted$separator$after';
    return (newText, before.length + inserted.length + separator.length);
  }
}
