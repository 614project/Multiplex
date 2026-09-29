import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/path_safety.dart';
import '../models/image_metadata.dart';
import '../services/file_io.dart';
import '../services/image_export_service.dart';
import 'layout.dart';

/// File, share and gallery operations that differ between desktop and mobile.
abstract final class PlatformActions {
  static Future<void> openFolder(String folderPath) async {
    await Directory(folderPath).create(recursive: true);
    await launchUrl(Uri.directory(folderPath));
  }

  static Future<void> openFile(String filePath) async {
    if (await File(filePath).exists()) {
      await launchUrl(Uri.file(filePath));
    }
  }

  static Rect? _shareOrigin(BuildContext context) {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
  }

  static Future<void> shareFiles(BuildContext context, List<String> paths, {String? text}) async {
    if (paths.isEmpty) {
      return;
    }

    await SharePlus.instance.share(
      ShareParams(
        files: [for (final path in paths) XFile(path)],
        text: text,
        sharePositionOrigin: _shareOrigin(context),
      ),
    );
  }

  /// Saves images into the photo library (mobile). Returns how many were saved.
  static Future<int> saveToGallery(List<String> paths, {CollectImageFormat? format}) async {
    if (!await Gal.hasAccess(toAlbum: true)) {
      await Gal.requestAccess(toAlbum: true);
    }

    var saved = 0;
    for (final path in paths) {
      if (!await File(path).exists()) {
        continue;
      }

      if (format == null || format == CollectImageFormat.pngPreserveMetadata) {
        await Gal.putImage(path, album: 'Multiplex');
      } else {
        final bytes = await ImageExportService.encode(path, format);
        await Gal.putImageBytes(bytes, album: 'Multiplex', name: p.basenameWithoutExtension(path));
      }

      saved++;
    }

    return saved;
  }

  /// Copies images into a folder chosen by the user (desktop). Returns how many were copied, or null
  /// when the picker was cancelled.
  static Future<int?> copyToChosenFolder(List<String> paths) async {
    final folder = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder');
    if (folder == null) {
      return null;
    }

    final reserved = <String>{};
    var copied = 0;
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) {
        continue;
      }

      final name = FileIo.uniqueFileName(
        folder,
        PathSafety.sanitizeFileName(p.basenameWithoutExtension(path)),
        p.extension(path),
        reserved: reserved,
      );
      await file.copy(p.join(folder, name));
      copied++;
    }

    return copied;
  }

  /// Saves the given images where the platform expects them: the photo library on mobile, a chosen
  /// folder on desktop. Returns a message for the user, or null when cancelled.
  static Future<String?> saveImages(List<String> paths) async {
    if (paths.isEmpty) {
      return null;
    }

    if (PlatformInfo.canSaveToGallery) {
      final saved = await saveToGallery(paths);
      return saved == 1 ? 'Saved 1 image to Photos.' : 'Saved $saved images to Photos.';
    }

    final copied = await copyToChosenFolder(paths);
    if (copied == null) {
      return null;
    }

    return copied == 1 ? 'Saved 1 image.' : 'Saved $copied images.';
  }

  /// Writes the named images in [format] to a folder (desktop) or the photo library (mobile).
  /// Returns a message for the user, or null when cancelled.
  static Future<String?> collect(List<({String name, String path})> images, CollectImageFormat format) async {
    if (images.isEmpty) {
      return 'No images were found to collect.';
    }

    if (PlatformInfo.canSaveToGallery) {
      final saved = await saveToGallery(images.map((image) => image.path).toList(), format: format);
      return 'Collected $saved images into Photos as ${format.title}.';
    }

    final folder = await FilePicker.getDirectoryPath(dialogTitle: 'Collect images into');
    if (folder == null) {
      return null;
    }

    final reserved = <String>{};
    for (final image in images) {
      final name = FileIo.uniqueFileName(
        folder,
        PathSafety.sanitizeFileName(image.name, fallback: 'Cell'),
        format.extension,
        reserved: reserved,
      );
      await ImageExportService.export(image.path, p.join(folder, name), format);
    }

    return 'Collected ${images.length} images into the folder as ${format.title}.';
  }

  /// Lets the user save a JSON document. Returns false when cancelled.
  static Future<bool> saveJson(BuildContext context, String fileName, String json) async {
    final bytes = Uint8List.fromList(utf8.encode(json));
    if (PlatformInfo.isMobile) {
      // Sharing reaches Files, Drive, chat apps and "Save to device" on both mobile platforms.
      final directory = await getTemporaryDirectory();
      final file = File(p.join(directory.path, fileName));
      await file.writeAsBytes(bytes, flush: true);
      if (!context.mounted) {
        return false;
      }

      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json')],
          sharePositionOrigin: _shareOrigin(context),
        ),
      );
      return result.status != ShareResultStatus.dismissed;
    }

    final saved = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: 'application/json',
      dialogTitle: 'Export',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    return saved != null;
  }

  /// Lets the user pick one or more JSON files and returns their contents.
  static Future<List<String>> pickJsonFiles() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Import projects',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    return [for (final file in files) utf8.decode(await file.readAsBytes(), allowMalformed: true)];
  }

  static Future<Uint8List?> pickCsvFile() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Import autocomplete CSV',
      type: FileType.custom,
      allowedExtensions: const ['csv', 'txt'],
    );
    return file?.readAsBytes();
  }
}
