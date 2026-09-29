import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/image_timestamps.dart';
import '../../models/image_metadata.dart';
import '../../state/app_state.dart';
import '../../state/cell_gallery.dart';
import '../../state/project_session.dart';
import '../common/number_field.dart';
import '../theme.dart';

/// Generation details read from the selected image's PNG metadata.
class MetadataPanel extends StatelessWidget {
  const MetadataPanel({
    super.key,
    required this.gallery,
    this.scrollController,
    this.padding = const EdgeInsets.all(20),
  });

  final CellGallery gallery;
  final ScrollController? scrollController;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final image = gallery.primary;
    if (image == null) {
      return Center(
        child: Text(
          gallery.selectedCount > 1
              ? '${gallery.selectedCount} images selected'
              : 'Select an image to see its details.',
          style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      );
    }

    return FutureBuilder<GeneratedImageMetadata>(
      key: ValueKey(image.path),
      future: gallery.metadataFor(image),
      builder: (context, snapshot) {
        final metadata = snapshot.data;
        if (metadata == null) {
          return const Center(child: CircularProgressIndicator());
        }

        return _MetadataContent(
          session: gallery.session,
          metadata: metadata,
          scrollController: scrollController,
          padding: padding,
        );
      },
    );
  }
}

class _MetadataContent extends StatelessWidget {
  const _MetadataContent({
    required this.session,
    required this.metadata,
    required this.scrollController,
    required this.padding,
  });

  final ProjectSession session;
  final GeneratedImageMetadata metadata;
  final ScrollController? scrollController;
  final EdgeInsets padding;

  void _copy(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    context.read<AppState>().messenger.success('$label copied.');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    String orUnavailable(String? value) => value == null || value.isEmpty ? 'Unavailable' : value;
    final stats = <(IconData, String, String)>[
      (Icons.stairs_outlined, 'Steps', orUnavailable(metadata.steps?.toString())),
      (
        Icons.speed,
        'CFG scale',
        orUnavailable(metadata.cfgScale == null ? null : NumberField.format(metadata.cfgScale, 3)),
      ),
      (Icons.blur_on, 'Sampler', orUnavailable(metadata.sampler)),
      (Icons.timeline, 'Scheduler', orUnavailable(metadata.scheduler)),
      (Icons.layers_clear_outlined, 'CLIP skip', orUnavailable(metadata.clipSkip?.toString())),
      (Icons.aspect_ratio, 'Size', metadata.sizeText),
    ];

    return ListView(
      controller: scrollController,
      padding: padding,
      children: [
        Row(
          children: [
            Expanded(child: Text('Image details', style: context.text.titleLarge)),
            if (metadata.metadataSource.isNotEmpty)
              Chip(
                label: Text(metadata.metadataSource),
                visualDensity: VisualDensity.compact,
                backgroundColor: colors.tertiaryContainer,
                side: BorderSide.none,
              ),
          ],
        ),
        Text(
          ImageTimestamps.format(metadata.generatedAt),
          style: context.text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        if (metadata.parseStatusMessage.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: colors.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: colors.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(child: Text(metadata.parseStatusMessage, style: context.text.bodySmall)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 520 ? 3 : 2;
            final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (icon, label, value) in stats)
                  SizedBox(
                    width: width,
                    child: _StatTile(icon: icon, label: label, value: value),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        _StatTile(icon: Icons.inventory_2_outlined, label: 'Checkpoint', value: orUnavailable(metadata.checkpoint)),
        const SizedBox(height: 8),
        _StatTile(
          icon: Icons.casino_outlined,
          label: 'Seed',
          value: orUnavailable(metadata.seed?.toString()),
          trailing: metadata.seed == null
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Copy seed',
                      onPressed: () => _copy(context, 'Seed', '${metadata.seed}'),
                      icon: const Icon(Icons.copy, size: 18),
                    ),
                    TextButton(
                      onPressed: () {
                        session.edit((settings) => settings.seed = metadata.seed!);
                        context.read<AppState>().messenger.success('Project seed set to ${metadata.seed}.');
                      },
                      child: const Text('Use'),
                    ),
                  ],
                ),
        ),
        if (metadata.loras.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final lora in metadata.loras)
                Chip(
                  avatar: const Icon(Icons.layers_outlined, size: 16),
                  label: Text(lora),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
        if (metadata.enableHiresFix == true) ...[
          const SizedBox(height: 8),
          _StatTile(
            icon: Icons.high_quality_outlined,
            label: 'Hires.fix',
            value: [
              if (metadata.hiresSteps != null) '${metadata.hiresSteps} steps',
              if (metadata.hiresDenoisingStrength != null)
                'denoise ${NumberField.format(metadata.hiresDenoisingStrength, 3)}',
            ].join(' · '),
          ),
        ],
        const SizedBox(height: 16),
        _PromptBlock(
          label: 'Positive prompt',
          text: metadata.positivePrompt,
          onCopy: () => _copy(context, 'Positive prompt', metadata.positivePrompt),
        ),
        const SizedBox(height: 12),
        _PromptBlock(
          label: 'Negative prompt',
          text: metadata.negativePrompt,
          onCopy: () => _copy(context, 'Negative prompt', metadata.negativePrompt),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.icon, required this.label, required this.value, this.trailing});

  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(color: colors.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: context.text.labelSmall?.copyWith(color: colors.onSurfaceVariant)),
                SelectableText(value, style: context.text.bodyMedium, maxLines: 3),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _PromptBlock extends StatelessWidget {
  const _PromptBlock({required this.label, required this.text, required this.onCopy});

  final String label;
  final String text;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 14),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: context.text.labelLarge)),
              IconButton(
                tooltip: 'Copy',
                onPressed: text.isEmpty ? null : onCopy,
                icon: const Icon(Icons.copy, size: 18),
              ),
            ],
          ),
          SelectableText(
            text.isEmpty ? '—' : text,
            style: context.text.bodyMedium?.copyWith(
              height: 1.45,
              color: text.isEmpty ? colors.onSurfaceVariant : null,
            ),
          ),
        ],
      ),
    );
  }
}
