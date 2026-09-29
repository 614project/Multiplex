import 'package:path/path.dart' as p;

abstract final class PathSafety {
  static final RegExp _drivePrefix = RegExp(r'^[A-Za-z]:');

  /// A path that comes from an imported file must be relative and must not climb out of the
  /// folder it is resolved against.
  static bool isSafeRelativePath(String? relativePath) {
    if (relativePath == null ||
        relativePath.trim().isEmpty ||
        relativePath.startsWith('/') ||
        relativePath.startsWith(r'\') ||
        _drivePrefix.hasMatch(relativePath) ||
        relativePath.contains('\u0000')) {
      return false;
    }

    final segments = relativePath.split(RegExp(r'[/\\]')).where((segment) => segment.isNotEmpty).toList();
    return segments.isNotEmpty && segments.every((segment) => segment != '..' && !segment.contains(':'));
  }

  /// Resolves a stored path (relative to [rootFolder], or absolute) and returns null unless the
  /// result lies strictly inside [rootFolder].
  static String? tryResolveWithinRoot(String rootFolder, String? storedPath, {p.Context? context}) {
    final pathContext = context ?? p.context;
    if (rootFolder.trim().isEmpty ||
        storedPath == null ||
        storedPath.trim().isEmpty ||
        storedPath.contains('\u0000')) {
      return null;
    }

    final normalizedStored = pathContext.style == p.Style.windows
        ? storedPath.replaceAll('/', r'\')
        : storedPath.replaceAll(r'\', '/');
    final root = pathContext.normalize(pathContext.absolute(rootFolder));
    final candidate = pathContext.normalize(
      pathContext.isAbsolute(normalizedStored)
          ? normalizedStored
          : pathContext.join(root, normalizedStored),
    );

    return pathContext.isWithin(root, candidate) ? candidate : null;
  }

  /// Converts an absolute path inside [rootFolder] to the portable form stored in project files.
  static String toPortableRelative(String rootFolder, String fullPath, {p.Context? context}) {
    final pathContext = context ?? p.context;
    return pathContext.relative(fullPath, from: rootFolder).replaceAll(r'\', '/');
  }

  static final RegExp _invalidFileNameCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

  /// Makes a user supplied name usable as a file name on every platform.
  static String sanitizeFileName(String name, {String fallback = 'Image'}) {
    var sanitized = name.replaceAll(_invalidFileNameCharacters, '_').trim();
    while (sanitized.endsWith('.')) {
      sanitized = sanitized.substring(0, sanitized.length - 1);
    }

    return sanitized.isEmpty ? fallback : sanitized;
  }
}
