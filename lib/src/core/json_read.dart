/// Lenient readers for decoded JSON. Keys are matched case-insensitively so files written by
/// WebuiMultiflex (PascalCase) and Multiplex (camelCase) can both be read.
abstract final class JsonRead {
  static Map<String, Object?>? map(Object? value) {
    if (value is Map<String, Object?>) {
      return value;
    }

    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item as Object?));
    }

    return null;
  }

  static List<Object?>? list(Object? value) => value is List ? value.cast<Object?>() : null;

  static Object? value(Map<String, Object?> map, String key) {
    if (map.containsKey(key)) {
      return map[key];
    }

    final lower = key.toLowerCase();
    for (final entry in map.entries) {
      if (entry.key.toLowerCase() == lower) {
        return entry.value;
      }
    }

    return null;
  }

  static String? string(Map<String, Object?> map, String key) {
    final result = value(map, key);
    return result is String ? result : null;
  }

  static num? number(Map<String, Object?> map, String key) {
    final result = value(map, key);
    if (result is num) {
      return result;
    }

    if (result is String) {
      return num.tryParse(result.trim());
    }

    return null;
  }

  static int? integer(Map<String, Object?> map, String key) {
    final result = number(map, key);
    if (result == null || result.isNaN || result.isInfinite) {
      return null;
    }

    return result.round();
  }

  static bool? boolean(Map<String, Object?> map, String key) {
    final result = value(map, key);
    if (result is bool) {
      return result;
    }

    if (result is String) {
      final lower = result.toLowerCase();
      if (lower == 'true') {
        return true;
      }

      if (lower == 'false') {
        return false;
      }
    }

    return null;
  }

  static DateTime? dateTime(Map<String, Object?> map, String key) {
    final result = string(map, key);
    return result == null ? null : DateTime.tryParse(result)?.toLocal();
  }
}
