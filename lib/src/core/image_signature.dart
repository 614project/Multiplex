import 'dart:convert';
import 'dart:typed_data';

abstract final class ImageSignature {
  static const defaultExtension = '.png';
  static const supportedExtensions = {'.png', '.jpg', '.jpeg', '.webp', '.bmp'};

  /// Picks the file extension from the image signature, because WebUI can be configured to return
  /// JPEG or WebP and recovered previews are not guaranteed to be PNG.
  static String detectExtension(List<int> bytes) => tryDetectExtension(bytes) ?? defaultExtension;

  /// The extension matching the image signature, or null when [bytes] is not a PNG, JPEG, WebP or BMP.
  static String? tryDetectExtension(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return '.png';
    }

    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return '.jpg';
    }

    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }

    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return '.bmp';
    }

    return null;
  }

  /// Reads width and height from a PNG header, or null for other formats.
  static ({int width, int height})? tryReadPngSize(List<int> bytes) {
    if (bytes.length < 24 || bytes[0] != 137 || bytes[1] != 80 || bytes[2] != 78 || bytes[3] != 71) {
      return null;
    }

    final width = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final height = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    return width > 0 && height > 0 ? (width: width, height: height) : null;
  }

  /// Strips a `data:image/png;base64,` prefix.
  static String stripDataUriPrefix(String base64Text) {
    final commaIndex = base64Text.indexOf(',');
    return commaIndex >= 0 ? base64Text.substring(commaIndex + 1) : base64Text;
  }

  /// Decodes base64 image data (with or without a data URI prefix), or returns null when invalid.
  static Uint8List? tryDecodeBase64(String? text) {
    if (text == null || text.trim().isEmpty) {
      return null;
    }

    try {
      return base64.decode(base64.normalize(stripDataUriPrefix(text).trim()));
    } on FormatException {
      return null;
    }
  }
}
