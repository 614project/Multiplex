import 'package:flutter/material.dart';

import '../../models/image_metadata.dart';
import '../../state/cell_model.dart';
import '../../state/project_session.dart';
import '../common/number_field.dart';
import '../common/prompt_field.dart';
import '../theme.dart';

/// Per-cell overrides; empty numeric fields fall back to the project settings.
class CellOverridesForm extends StatelessWidget {
  const CellOverridesForm({super.key, required this.session, required this.cell});

  final ProjectSession session;
  final CellModel cell;

  void _set({
    int? steps,
    double? cfg,
    int? width,
    int? height,
    String? negative,
    bool clearSteps = false,
    bool clearCfg = false,
    bool clearWidth = false,
    bool clearHeight = false,
  }) {
    cell.setOverrides(
      steps: clearSteps ? null : (steps ?? cell.overrideSteps),
      cfgScale: clearCfg ? null : (cfg ?? cell.overrideCfgScale),
      width: clearWidth ? null : (width ?? cell.overrideWidth),
      height: clearHeight ? null : (height ?? cell.overrideHeight),
      negativePrompt: negative ?? cell.overrideNegativePrompt,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = session.settings;
    return ListenableBuilder(
      listenable: cell,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: NumberField(
                  label: 'Steps',
                  hint: 'Project (${settings.steps})',
                  value: cell.overrideSteps,
                  allowEmpty: true,
                  min: 1,
                  max: 150,
                  onChanged: (value) => value == null ? _set(clearSteps: true) : _set(steps: value.toInt()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NumberField(
                  label: 'CFG scale',
                  hint: 'Project (${NumberField.format(settings.cfgScale, 1)})',
                  value: cell.overrideCfgScale,
                  allowEmpty: true,
                  min: 1,
                  max: 30,
                  step: 0.5,
                  decimals: 2,
                  onChanged: (value) => value == null ? _set(clearCfg: true) : _set(cfg: value.toDouble()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: NumberField(
                  label: 'Width',
                  hint: 'Project (${settings.width})',
                  value: cell.overrideWidth,
                  allowEmpty: true,
                  min: 64,
                  max: 4096,
                  step: 64,
                  onChanged: (value) => value == null ? _set(clearWidth: true) : _set(width: value.toInt()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NumberField(
                  label: 'Height',
                  hint: 'Project (${settings.height})',
                  value: cell.overrideHeight,
                  allowEmpty: true,
                  min: 64,
                  max: 4096,
                  step: 64,
                  onChanged: (value) => value == null ? _set(clearHeight: true) : _set(height: value.toInt()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          PromptField(
            label: 'Additional negative prompt',
            hint: 'Appended to the project negative prompt for this cell only',
            value: cell.overrideNegativePrompt,
            minLines: 2,
            maxLines: 6,
            onChanged: (value) => _set(negative: value),
          ),
        ],
      ),
    );
  }
}

Future<void> showCellOverridesDialog(BuildContext context, ProjectSession session, CellModel cell) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Overrides · ${cell.displayName}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Leave a numeric field blank to use the project value. Changes are saved automatically.',
                style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              CellOverridesForm(session: session, cell: cell),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            cell.setOverrides(steps: null, cfgScale: null, width: null, height: null, negativePrompt: '');
            Navigator.pop(context);
          },
          child: const Text('Clear all'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    ),
  );
}

Future<CollectImageFormat?> showCollectFormatDialog(
  BuildContext context, {
  required int imageCount,
  required bool toGallery,
}) {
  return showDialog<CollectImageFormat>(
    context: context,
    builder: (context) => _CollectFormatDialog(imageCount: imageCount, toGallery: toGallery),
  );
}

class _CollectFormatDialog extends StatefulWidget {
  const _CollectFormatDialog({required this.imageCount, required this.toGallery});

  final int imageCount;
  final bool toGallery;

  @override
  State<_CollectFormatDialog> createState() => _CollectFormatDialogState();
}

class _CollectFormatDialogState extends State<_CollectFormatDialog> {
  CollectImageFormat _format = CollectImageFormat.pngPreserveMetadata;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Collect images'),
      content: SizedBox(
        width: 460,
        child: RadioGroup<CollectImageFormat>(
          groupValue: _format,
          onChanged: (value) => setState(() => _format = value ?? _format),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.toGallery
                    ? 'Saves the shown image of ${widget.imageCount} cell(s) to your photo library.'
                    : 'Writes the shown image of ${widget.imageCount} cell(s) into a folder, named after the cells.',
                style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              for (final format in CollectImageFormat.values)
                RadioListTile<CollectImageFormat>(
                  value: format,
                  title: Text(format.title),
                  subtitle: Text(format.description),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _format), child: const Text('Continue')),
      ],
    );
  }
}
