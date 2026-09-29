import '../core/json_read.dart';

class LoraSelection {
  const LoraSelection({required this.name, this.weight = 1.0});

  final String name;
  final double weight;

  static const minimumWeight = -4.0;
  static const maximumWeight = 4.0;

  LoraSelection copyWith({String? name, double? weight}) =>
      LoraSelection(name: name ?? this.name, weight: weight ?? this.weight);

  Map<String, Object?> toJson() => {'name': name, 'weight': weight};

  /// Accepts both camelCase (Multiplex) and PascalCase (WebuiMultiflex) keys.
  static LoraSelection? fromJson(Object? json) {
    final map = JsonRead.map(json);
    if (map == null) {
      return null;
    }

    return LoraSelection(
      name: JsonRead.string(map, 'name') ?? '',
      weight: JsonRead.number(map, 'weight')?.toDouble() ?? 1.0,
    );
  }

  static double normalizeWeight(double value) {
    if (value.isNaN || value.isInfinite) {
      return 1.0;
    }

    return value.clamp(minimumWeight, maximumWeight).toDouble();
  }

  /// Trims names, drops blanks, removes case-insensitive duplicates (first wins) and clamps weights.
  static List<LoraSelection> normalize(Iterable<LoraSelection?>? loras) {
    if (loras == null) {
      return <LoraSelection>[];
    }

    final seen = <String>{};
    final result = <LoraSelection>[];
    for (final lora in loras) {
      if (lora == null) {
        continue;
      }

      final name = lora.name.trim();
      if (name.isEmpty || !seen.add(name.toLowerCase())) {
        continue;
      }

      result.add(LoraSelection(name: name, weight: normalizeWeight(lora.weight)));
    }

    return result;
  }

  static String formatWeight(double weight) {
    final normalized = normalizeWeight(weight);
    var text = normalized.toStringAsFixed(3);
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) {
      text = text.substring(0, text.length - 1);
    }

    return text == '-0' ? '0' : text;
  }

  @override
  bool operator ==(Object other) => other is LoraSelection && other.name == name && other.weight == weight;

  @override
  int get hashCode => Object.hash(name, weight);

  @override
  String toString() => '$name (${formatWeight(weight)})';
}
