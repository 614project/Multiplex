import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../models/image_metadata.dart';

/// Writes collected images in the requested format.
abstract final class ImageExportService {
  /// Produces the bytes of [sourcePath] converted to [format].
  static Future<Uint8List> encode(String sourcePath, CollectImageFormat format) async {
    final bytes = await File(sourcePath).readAsBytes();
    if (format == CollectImageFormat.pngPreserveMetadata && p.extension(sourcePath).toLowerCase() == '.png') {
      return bytes;
    }

    return Isolate.run(() => _convert(bytes, format));
  }

  static Future<void> export(String sourcePath, String destinationPath, CollectImageFormat format) async {
    final bytes = await encode(sourcePath, format);
    final destination = File(destinationPath);
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes, flush: true);
  }

  static Uint8List _convert(Uint8List bytes, CollectImageFormat format) {
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw const FormatException('The image could not be decoded.');
    }

    switch (format) {
      case CollectImageFormat.pngPreserveMetadata:
        return img.encodePng(image);
      case CollectImageFormat.pngWithoutMetadata:
        image.textData = null;
        image.exif = img.ExifData();
        image.iccProfile = null;
        return img.encodePng(image);
      case CollectImageFormat.jpeg:
        image.textData = null;
        image.exif = img.ExifData();
        return img.encodeJpg(image.hasAlpha ? _flatten(image) : image, quality: 92);
    }
  }

  static img.Image _flatten(img.Image image) {
    final background = img.Image(width: image.width, height: image.height, numChannels: 3);
    img.fill(background, color: img.ColorRgb8(255, 255, 255));
    return img.compositeImage(background, image);
  }
}
