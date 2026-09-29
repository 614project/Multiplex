import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// File helpers that never leave a half-written file behind.
abstract final class FileIo {
  /// Writes to a temporary sibling file first and then renames it over [path].
  static Future<void> writeBytesAtomic(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temporary = File('$path.partial');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(path);
    } catch (_) {
      try {
        if (await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {
        // Best effort cleanup.
      }

      rethrow;
    }
  }

  static Future<void> writeStringAtomic(String path, String text) => writeBytesAtomic(path, utf8.encode(text));

  static Future<Object?> readJson(String path) async {
    final text = await File(path).readAsString();
    return jsonDecode(text);
  }

  static Future<Uint8List?> tryReadBytes(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<void> copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final name = entity.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
      if (entity is File) {
        await entity.copy('${destination.path}${Platform.pathSeparator}$name');
      } else if (entity is Directory) {
        await copyDirectory(entity, Directory('${destination.path}${Platform.pathSeparator}$name'));
      }
    }
  }

  /// Returns a file name in [folder] based on [baseName] that is not taken yet (and not in [reserved]).
  static String uniqueFileName(String folder, String baseName, String extension, {Set<String>? reserved}) {
    var candidate = '$baseName$extension';
    var suffix = 1;
    bool taken(String name) =>
        (reserved?.contains(name.toLowerCase()) ?? false) || File('$folder${Platform.pathSeparator}$name').existsSync();
    while (taken(candidate)) {
      candidate = '${baseName}_$suffix$extension';
      suffix++;
    }

    reserved?.add(candidate.toLowerCase());
    return candidate;
  }
}
