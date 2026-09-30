import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../core/ids.dart';
import '../core/image_signature.dart';
import 'file_io.dart';

/// Format and size of a source image, read from its header.
class SourceImageInfo {
  const SourceImageInfo({required this.width, required this.height, required this.extension});

  final int width;
  final int height;
  final String extension;

  String get sizeText => '$width × $height';
}

/// img2img source images. They are copied into the project's `sources` folder under generated
/// names, so a project keeps working when the original file moves and exports can carry them.
abstract final class SourceImages {
  static final Map<String, SourceImageInfo> _infoCache = {};

  /// Reads format and size without decoding the pixels; null when [bytes] is not a PNG, JPEG, WebP
  /// or BMP image.
  static SourceImageInfo? readInfo(Uint8List bytes) {
    final extension = ImageSignature.tryDetectExtension(bytes);
    if (extension == null) {
      return null;
    }

    try {
      final info = img.findDecoderForData(bytes)?.startDecode(bytes);
      if (info == null || info.width <= 0 || info.height <= 0) {
        return null;
      }

      return SourceImageInfo(width: info.width, height: info.height, extension: extension);
    } catch (_) {
      return null;
    }
  }

  /// Like [readInfo] for a file; source files never change after they are stored, so results are cached.
  static Future<SourceImageInfo?> readInfoFromFile(String path) async {
    final cached = _infoCache[path];
    if (cached != null) {
      return cached;
    }

    final bytes = await FileIo.tryReadBytes(path);
    final info = bytes == null ? null : readInfo(bytes);
    if (info != null) {
      _infoCache[path] = info;
    }

    return info;
  }

  /// Stores [bytes] in [folder] under a new name and returns the new file's path.
  static Future<String> store(String folder, Uint8List bytes) async {
    final info = readInfo(bytes);
    if (info == null) {
      throw const FormatException('Unsupported image. Choose a PNG, JPEG, WebP or BMP file.');
    }

    final path = p.join(folder, 'source-${newId().substring(0, 12)}${info.extension}');
    await FileIo.writeBytesAtomic(path, bytes);
    _infoCache[path] = info;
    return path;
  }
}
