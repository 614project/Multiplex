import 'dart:io';

import 'package:flutter/foundation.dart';

/// Appends diagnostics (unhandled errors, save failures, unreadable projects) to a rotating log file.
class AppLog {
  AppLog._();

  static const _maximumBytes = 2 * 1024 * 1024;
  static String? _path;
  static Future<void> _pending = Future<void>.value();

  static String? get path => _path;

  static void configure(String logFilePath) => _path = logFilePath;

  static void write(String category, Object? details, [StackTrace? stackTrace]) {
    debugPrint('[Multiplex] $category: $details');
    final path = _path;
    if (path == null) {
      return;
    }

    final entry = StringBuffer()
      ..writeln('[${DateTime.now().toIso8601String()}] $category:')
      ..writeln(details);
    if (stackTrace != null) {
      entry.writeln(stackTrace);
    }

    entry.writeln();
    _pending = _pending.then((_) => _append(path, entry.toString())).catchError((Object _) {});
  }

  static Future<void> _append(String path, String text) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      if (await file.exists() && await file.length() > _maximumBytes) {
        final old = File('$path.old');
        if (await old.exists()) {
          await old.delete();
        }

        await file.rename(old.path);
      }

      await file.writeAsString(text, mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging must never throw; there is nowhere left to report the failure.
    }
  }
}
