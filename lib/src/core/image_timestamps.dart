import 'dart:io';

import 'package:path/path.dart' as p;

/// Generated images are named `yyyyMMdd_HHmmssfff` (local time), optionally with a `_n` suffix.
abstract final class ImageTimestamps {
  static final RegExp _pattern = RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})(\d{3})(?:_\d+)?$');

  static String fileBaseName(DateTime time) {
    String pad(int value, int width) => value.toString().padLeft(width, '0');
    return '${pad(time.year, 4)}${pad(time.month, 2)}${pad(time.day, 2)}_'
        '${pad(time.hour, 2)}${pad(time.minute, 2)}${pad(time.second, 2)}${pad(time.millisecond, 3)}';
  }

  static DateTime? tryParseFileName(String filePath) {
    final match = _pattern.firstMatch(p.basenameWithoutExtension(filePath));
    if (match == null) {
      return null;
    }

    int group(int index) => int.parse(match.group(index)!);
    return DateTime(group(1), group(2), group(3), group(4), group(5), group(6), group(7));
  }

  /// The time encoded in the file name, falling back to the file's modification time.
  static DateTime resolve(String filePath) {
    final parsed = tryParseFileName(filePath);
    if (parsed != null) {
      return parsed;
    }

    try {
      return File(filePath).lastModifiedSync();
    } catch (_) {
      return DateTime.now();
    }
  }

  static String format(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  static String formatShort(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}
