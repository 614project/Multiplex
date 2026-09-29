/// Builds the effective prompts that are sent to the server.
///
/// Positive order: global addition, project prompt, cell prompt. When the project prompt contains
/// `<CELL_PROMPT>` the cell prompt is injected there instead of being appended.
/// Negative order: global addition, project negative prompt, cell negative override.
abstract final class PromptComposer {
  static const cellPromptPlaceholder = '<CELL_PROMPT>';

  static final RegExp _placeholderPattern = RegExp(RegExp.escape(cellPromptPlaceholder), caseSensitive: false);

  static String composePositivePrompt(String? globalPrompt, String? projectPrompt, String? cellPrompt) {
    final normalizedProjectPrompt = _normalizeSegment(projectPrompt);
    final normalizedCellPrompt = _normalizeSegment(cellPrompt);

    if (_placeholderPattern.hasMatch(normalizedProjectPrompt)) {
      // A replacement callback keeps characters such as '$' (used by Dynamic Prompts) literal.
      final replaced = normalizedProjectPrompt.replaceAllMapped(_placeholderPattern, (_) => normalizedCellPrompt);
      return mergePromptSegments([globalPrompt, replaced]);
    }

    return mergePromptSegments([globalPrompt, normalizedProjectPrompt, normalizedCellPrompt]);
  }

  static String composeNegativePrompt(String? globalPrompt, String? projectPrompt, String? cellPrompt) {
    return mergePromptSegments([globalPrompt, projectPrompt, cellPrompt]);
  }

  /// Joins segments with a single comma, collapsing duplicate or missing commas at the seams.
  static String mergePromptSegments(Iterable<String?> segments) {
    var merged = '';
    for (final segment in segments) {
      merged = _mergePair(merged, segment);
    }

    return merged;
  }

  static String _mergePair(String? left, String? right) {
    final normalizedLeft = _normalizeSegment(left);
    final normalizedRight = _normalizeSegment(right);

    if (normalizedLeft.isEmpty) {
      return normalizedRight;
    }

    if (normalizedRight.isEmpty) {
      return normalizedLeft;
    }

    final leftEndsWithComma = normalizedLeft.endsWith(',');
    final rightStartsWithComma = normalizedRight.startsWith(',');

    if (!leftEndsWithComma && !rightStartsWithComma) {
      return '$normalizedLeft,$normalizedRight';
    }

    if (leftEndsWithComma && rightStartsWithComma) {
      return normalizedLeft + normalizedRight.substring(1);
    }

    return normalizedLeft + normalizedRight;
  }

  static String _normalizeSegment(String? segment) => segment == null || segment.trim().isEmpty ? '' : segment.trim();
}
