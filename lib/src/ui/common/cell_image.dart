import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Loads an image file scaled down to the size it is displayed at, to keep memory low on phones.
class FileThumbnail extends StatelessWidget {
  const FileThumbnail({
    super.key,
    required this.path,
    this.fit = BoxFit.cover,
    this.decodeWidth,
    this.alignment = Alignment.center,
  });

  final String path;
  final BoxFit fit;

  /// Logical width the image is decoded at (multiplied by the device pixel ratio).
  final double? decodeWidth;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = decodeWidth == null ? null : (decodeWidth! * ratio).round();
    return Image.file(
      File(path),
      fit: fit,
      alignment: alignment,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => const ImagePlaceholder(icon: Icons.broken_image_outlined),
    );
  }
}

class MemoryPreview extends StatelessWidget {
  const MemoryPreview({super.key, required this.bytes, this.fit = BoxFit.cover});

  final Uint8List bytes;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      bytes,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
    );
  }
}

class ImagePlaceholder extends StatelessWidget {
  const ImagePlaceholder({super.key, this.icon = Icons.image_outlined, this.label});

  /// The centered icon, or null for a plain background (e.g. under a progress indicator).
  final IconData? icon;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.surfaceContainerHighest, colors.surfaceContainer],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, color: colors.onSurfaceVariant.withValues(alpha: 0.6), size: 32),
            if (label != null) ...[
              const SizedBox(height: 6),
              Text(label!, style: context.text.labelMedium?.copyWith(color: colors.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}
