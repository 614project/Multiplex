import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/sd_client.dart';
import '../../services/source_images.dart';
import '../../state/app_state.dart';
import '../../state/cell_model.dart';
import '../../state/project_session.dart';
import '../platform_actions.dart';
import '../theme.dart';
import 'cell_image.dart';

/// Lets the user pick an image and stores it as a source image of [session]. Returns the stored
/// copy's path, or null when the picker was cancelled or the file is not a supported image.
Future<String?> pickSourceImage(BuildContext context, ProjectSession session) async {
  final messenger = context.read<AppState>().messenger;
  try {
    final bytes = await PlatformActions.pickImage();
    return bytes == null ? null : await session.storeSourceImage(bytes);
  } on FormatException catch (error) {
    messenger.error(error.message);
  } catch (error) {
    messenger.error('Could not use that image: ${SdClient.describeError(error)}');
  }

  return null;
}

Future<void> chooseProjectSourceImage(BuildContext context, ProjectSession session) async {
  final path = await pickSourceImage(context, session);
  if (path != null) {
    await session.setProjectSourceImage(path);
  }
}

Future<void> chooseCellSourceImage(BuildContext context, ProjectSession session, CellModel cell) async {
  final path = await pickSourceImage(context, session);
  if (path != null) {
    await session.setCellSourceImage(cell, path);
  }
}

/// "1024 × 768 · PNG" for a source image file.
class SourceImageInfoText extends StatefulWidget {
  const SourceImageInfoText({super.key, required this.path, this.style});

  final String path;
  final TextStyle? style;

  @override
  State<SourceImageInfoText> createState() => _SourceImageInfoTextState();
}

class _SourceImageInfoTextState extends State<SourceImageInfoText> {
  late Future<SourceImageInfo?> _info = SourceImages.readInfoFromFile(widget.path);

  @override
  void didUpdateWidget(SourceImageInfoText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _info = SourceImages.readInfoFromFile(widget.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SourceImageInfo?>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final text = snapshot.connectionState != ConnectionState.done
            ? ' '
            : info == null
            ? 'The image file is missing'
            : '${info.sizeText} · ${info.extension.substring(1).toUpperCase()}';
        return Text(
          text,
          style: widget.style ?? context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
        );
      },
    );
  }
}

/// A source image thumbnail. [inherited] dims it, for cells that use the project's image;
/// without a [path] it shows an "add image" placeholder.
class SourceThumbnail extends StatelessWidget {
  const SourceThumbnail({super.key, required this.path, required this.size, this.inherited = false, this.radius = 12});

  final String? path;
  final double size;
  final bool inherited;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final path = this.path;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: path == null
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(radius),
                ),
                child: Icon(Icons.add_photo_alternate_outlined, size: size * 0.45, color: colors.onSurfaceVariant),
              )
            : Opacity(
                opacity: inherited ? 0.55 : 1,
                child: FileThumbnail(path: path, decodeWidth: size),
              ),
      ),
    );
  }
}

/// Thumbnail, size and choose/clear buttons for a source image.
class SourceImagePanel extends StatelessWidget {
  const SourceImagePanel({
    super.key,
    required this.path,
    required this.title,
    required this.onChoose,
    this.onClear,
    this.clearLabel = 'Remove',
    this.inherited = false,
    this.emptyText = 'No source image yet',
    this.enabled = true,
    this.thumbnailSize = 88,
  });

  final String? path;
  final String title;
  final VoidCallback onChoose;
  final VoidCallback? onClear;
  final String clearLabel;

  /// The image shown is not this item's own (a cell showing the project's image).
  final bool inherited;
  final String emptyText;
  final bool enabled;
  final double thumbnailSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final path = this.path;
    return Row(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onChoose : null,
          child: SourceThumbnail(path: path, size: thumbnailSize, inherited: inherited),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.text.labelLarge),
              const SizedBox(height: 2),
              if (path == null)
                Text(emptyText, style: context.text.bodySmall?.copyWith(color: colors.error))
              else
                SourceImageInfoText(path: path),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: enabled ? onChoose : null,
                    icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                    label: Text(path == null || inherited ? 'Choose image' : 'Replace'),
                  ),
                  if (onClear != null) TextButton(onPressed: enabled ? onClear : null, child: Text(clearLabel)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Source image editor for one cell: its own image, or the project's shown dimmed.
class CellSourcePanel extends StatelessWidget {
  const CellSourcePanel({super.key, required this.session, required this.cell, this.thumbnailSize = 88});

  final ProjectSession session;
  final CellModel cell;
  final double thumbnailSize;

  @override
  Widget build(BuildContext context) {
    final own = cell.sourceImagePath;
    final project = session.projectSourceImagePath;
    return SourceImagePanel(
      path: own ?? project,
      inherited: own == null,
      thumbnailSize: thumbnailSize,
      title: own != null
          ? 'Source image · this cell'
          : project != null
          ? 'Source image · project'
          : 'Source image',
      emptyText: 'Choose one here or in the project settings',
      onChoose: () => chooseCellSourceImage(context, session, cell),
      onClear: own == null ? null : () => session.setCellSourceImage(cell, null),
      clearLabel: project == null ? 'Remove' : 'Use project image',
    );
  }
}

enum _CellSourceAction { choose, clear }

/// Small source thumbnail for cell cards; opens a menu to change the cell's source image.
class CellSourceButton extends StatelessWidget {
  const CellSourceButton({super.key, required this.session, required this.cell, this.size = 32});

  final ProjectSession session;
  final CellModel cell;
  final double size;

  @override
  Widget build(BuildContext context) {
    final own = cell.sourceImagePath;
    final effective = own ?? session.projectSourceImagePath;
    return PopupMenuButton<_CellSourceAction>(
      tooltip: own != null
          ? 'Source image of this cell'
          : effective != null
          ? 'Uses the project source image'
          : 'No source image',
      padding: EdgeInsets.zero,
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _CellSourceAction.choose,
          child: ListTile(leading: Icon(Icons.add_photo_alternate_outlined), title: Text('Choose source image…')),
        ),
        if (own != null)
          const PopupMenuItem(
            value: _CellSourceAction.clear,
            child: ListTile(leading: Icon(Icons.layers_clear_outlined), title: Text('Use project source image')),
          ),
      ],
      onSelected: (action) => switch (action) {
        _CellSourceAction.choose => chooseCellSourceImage(context, session, cell),
        _CellSourceAction.clear => session.setCellSourceImage(cell, null),
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: own != null
                  ? context.colors.primary
                  : effective == null
                  ? context.colors.error
                  : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: SourceThumbnail(path: effective, size: size, inherited: own == null, radius: 8),
        ),
      ),
    );
  }
}
