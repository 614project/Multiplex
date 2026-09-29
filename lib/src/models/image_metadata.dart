/// Generation details recovered from an image file (see `PngMetadataReader`).
class GeneratedImageMetadata {
  GeneratedImageMetadata({required this.filePath, required this.generatedAt});

  final String filePath;
  DateTime generatedAt;
  int width = 0;
  int height = 0;
  int baseWidth = 0;
  int baseHeight = 0;
  bool metadataParsed = false;
  String metadataSource = '';
  String parseStatusMessage = '';
  String positivePrompt = '';
  String negativePrompt = '';
  int? steps;
  double? cfgScale;
  String sampler = '';
  String scheduler = '';
  int? seed;
  String checkpoint = '';
  int? clipSkip;
  List<String> loras = const [];
  bool? enableHiresFix;
  int? hiresSteps;
  double? hiresDenoisingStrength;

  String get sizeText {
    if (width <= 0 || height <= 0) {
      return 'Unavailable';
    }

    final finalText = '$width × $height';
    if (enableHiresFix == true &&
        baseWidth > 0 &&
        baseHeight > 0 &&
        (baseWidth != width || baseHeight != height)) {
      return '$finalText (Hires.fix from $baseWidth × $baseHeight)';
    }

    return finalText;
  }
}

enum CollectImageFormat {
  pngPreserveMetadata(
    'PNG (Preserve metadata)',
    'Keeps the original PNG metadata when possible. Best for retaining WebUI or ComfyUI generation info.',
    '.png',
  ),
  pngWithoutMetadata(
    'PNG (Lightweight)',
    'Re-encodes PNG without metadata for a smaller, cleaner file.',
    '.png',
  ),
  jpeg(
    'JPEG',
    'Creates a lighter JPEG copy without metadata.',
    '.jpg',
  );

  const CollectImageFormat(this.title, this.description, this.extension);

  final String title;
  final String description;
  final String extension;
}
