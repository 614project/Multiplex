import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/url_tools.dart';
import '../../models/api_platform.dart';
import '../../models/lora_selection.dart';
import '../../state/app_state.dart';
import '../../state/project_session.dart';
import '../common/number_field.dart';
import '../common/prompt_field.dart';
import '../common/section_card.dart';
import '../common/server_status.dart';
import '../dialogs/model_pickers.dart';
import '../theme.dart';

const sizePresets = <(int, int)>[
  (512, 512),
  (512, 768),
  (768, 512),
  (768, 768),
  (1024, 1024),
  (832, 1216),
  (1216, 832),
  (896, 1152),
  (1152, 896),
  (768, 1344),
  (1344, 768),
];

/// Shared project settings: connection, model, prompts, sampling, Hires.fix and project overrides.
/// [compact] switches to collapsible sections with sliders and size presets for touch screens.
class ProjectSettingsView extends StatelessWidget {
  const ProjectSettingsView({super.key, required this.session, this.compact = false, this.bottomPadding = 24});

  final ProjectSession session;
  final bool compact;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    context.select<AppState, Object>(
      (app) => Object.hash(
        app.preferences.globalApiBaseUrl,
        app.preferences.defaultTimeoutSeconds,
        app.preferences.defaultClipSkip,
        app.preferences.defaultGenerationMode,
      ),
    );
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final left = [
          _ConnectionSection(session: session, compact: compact),
          _ModelSection(session: session, compact: compact),
          _PromptsSection(session: session, compact: compact),
        ];
        final right = [
          _SamplingSection(session: session, compact: compact),
          _HiresSection(session: session, compact: compact),
          _OverridesSection(session: session, compact: compact),
        ];

        if (compact) {
          return ListView(
            padding: EdgeInsets.fromLTRB(12, 8, 12, bottomPadding),
            children: [
              for (final section in [...left, ...right])
                Padding(padding: const EdgeInsets.only(bottom: 12), child: section),
            ],
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= 1000;
            Widget column(List<Widget> sections) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final section in sections) Padding(padding: const EdgeInsets.only(bottom: 16), child: section),
              ],
            );
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 16, 20, bottomPadding),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1480),
                  child: twoColumns
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: column(left)),
                            const SizedBox(width: 16),
                            Expanded(child: column(right)),
                          ],
                        )
                      : column([...left, ...right]),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ConnectionSection extends StatefulWidget {
  const _ConnectionSection({required this.session, required this.compact});

  final ProjectSession session;
  final bool compact;

  @override
  State<_ConnectionSection> createState() => _ConnectionSectionState();
}

class _ConnectionSectionState extends State<_ConnectionSection> {
  late final TextEditingController _url = TextEditingController(text: widget.session.settings.apiBaseUrl);
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(_ConnectionSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && _url.text != widget.session.settings.apiBaseUrl) {
      _url.text = widget.session.settings.apiBaseUrl;
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final colors = context.colors;
    return SectionCard(
      icon: Icons.dns_outlined,
      title: 'Server',
      subtitle: 'API base URL and platform',
      collapsible: widget.compact,
      initiallyExpanded: !widget.compact || session.serverStatus != ServerStatus.online,
      summary:
          '${session.settings.platform.label} · ${EndpointResolver.describe(session.resolvedApiBaseUrl)} · '
          '${serverStatusLabel(session.serverStatus)}',
      trailing: widget.compact ? null : StatusDot(status: session.serverStatus, size: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<ApiPlatform>(
            segments: const [
              ButtonSegment(value: ApiPlatform.webUi, label: Text('WebUI'), icon: Icon(Icons.web)),
              ButtonSegment(
                value: ApiPlatform.comfyUi,
                label: Text('ComfyUI'),
                icon: Icon(Icons.account_tree_outlined),
              ),
            ],
            selected: {session.settings.platform},
            onSelectionChanged: (selection) => session.setPlatform(selection.first),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _url,
            focusNode: _focus,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'API base URL',
              hintText: session.apiBaseUrlPlaceholder,
              helperText: session.apiBaseUrlDescription,
              helperMaxLines: 3,
              prefixIcon: const Icon(Icons.link),
            ),
            onChanged: session.setApiBaseUrl,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            decoration: BoxDecoration(color: colors.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                StatusDot(status: session.serverStatus),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    session.serverMessage.isEmpty ? serverStatusLabel(session.serverStatus) : session.serverMessage,
                    style: context.text.bodySmall,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Check connection',
                  onPressed: session.serverStatus == ServerStatus.checking ? null : session.refreshServer,
                  icon: session.serverStatus == ServerStatus.checking
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelSection extends StatelessWidget {
  const _ModelSection({required this.session, required this.compact});

  final ProjectSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final settings = session.settings;
    final colors = context.colors;
    final loras = LoraSelection.normalize(settings.selectedLoras);
    return SectionCard(
      icon: Icons.memory,
      title: 'Model',
      subtitle: 'Checkpoint and LoRAs from the server',
      collapsible: compact,
      initiallyExpanded: !compact,
      summary:
          '${session.checkpointDisplay} · ${loras.isEmpty ? 'no LoRAs' : '${loras.length} LoRA${loras.length == 1 ? '' : 's'}'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ModelRow(
            icon: Icons.inventory_2_outlined,
            title: 'Checkpoint',
            value: session.checkpointDisplay,
            muted: settings.checkpointModel.isEmpty,
            action: FilledButton.tonal(onPressed: () => pickCheckpoint(context, session), child: const Text('Choose')),
          ),
          const SizedBox(height: 12),
          _ModelRow(
            icon: Icons.layers_outlined,
            title: settings.platform.isComfyUi ? 'LoRAs · ${settings.comfyLoraLoaderType}' : 'LoRAs',
            value: loras.isEmpty ? 'No LoRAs selected' : null,
            muted: loras.isEmpty,
            action: FilledButton.tonal(onPressed: () => pickLoras(context, session), child: const Text('Choose')),
            below: loras.isEmpty
                ? null
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final lora in loras)
                        InputChip(
                          label: Text('${lora.name} · ${LoraSelection.formatWeight(lora.weight)}'),
                          backgroundColor: colors.tertiaryContainer.withValues(alpha: 0.5),
                          onDeleted: () => session.setLoras([...loras]..remove(lora)),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.icon,
    required this.title,
    required this.action,
    this.value,
    this.muted = false,
    this.below,
  });

  final IconData icon;
  final String title;
  final String? value;
  final bool muted;
  final Widget action;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(color: colors.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: colors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: context.text.labelLarge),
                    if (value != null)
                      Text(
                        value!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodyMedium?.copyWith(
                          color: muted ? colors.onSurfaceVariant : colors.onSurface,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              action,
            ],
          ),
          if (below != null) ...[const SizedBox(height: 10), below!],
        ],
      ),
    );
  }
}

class _PromptsSection extends StatelessWidget {
  const _PromptsSection({required this.session, required this.compact});

  final ProjectSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final settings = session.settings;
    return SectionCard(
      icon: Icons.notes,
      title: 'Prompts',
      subtitle: 'Shared by every cell of the project',
      collapsible: compact,
      summary: settings.commonPrompt.trim().isEmpty ? 'No shared prompt' : settings.commonPrompt.trim(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PromptField(
            label: 'Positive prompt',
            hint: 'Added to every cell. Put <CELL_PROMPT> where each cell prompt should be inserted.',
            value: settings.commonPrompt,
            minLines: compact ? 3 : 4,
            onChanged: (value) => session.edit((settings) => settings.commonPrompt = value),
          ),
          const SizedBox(height: 12),
          PromptField(
            label: 'Negative prompt',
            value: settings.negativePrompt,
            minLines: compact ? 2 : 3,
            onChanged: (value) => session.edit((settings) => settings.negativePrompt = value),
          ),
        ],
      ),
    );
  }
}

class _SamplingSection extends StatelessWidget {
  const _SamplingSection({required this.session, required this.compact});

  final ProjectSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final settings = session.settings;
    final seedText = settings.seed < 0 ? 'random seed' : 'seed ${settings.seed}';
    final optionsEnabled = !(settings.platform.isComfyUi && session.isComfyMetadataLoading);
    return SectionCard(
      icon: Icons.tune,
      title: 'Sampling',
      subtitle: 'Sampler, steps, CFG, size and seed',
      collapsible: compact,
      initiallyExpanded: !compact,
      summary:
          '${settings.samplerName} · ${settings.scheduler} · ${settings.steps} steps · '
          'CFG ${NumberField.format(settings.cfgScale, 2)} · ${settings.width}×${settings.height} · $seedText',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _responsiveRow(compact, [
            OptionDropdown(
              label: 'Sampler',
              value: settings.samplerName,
              options: session.samplerOptions,
              enabled: optionsEnabled,
              onSelected: (value) => session.edit((settings) => settings.samplerName = value),
            ),
            OptionDropdown(
              label: 'Scheduler',
              value: settings.scheduler,
              options: session.schedulerOptions,
              enabled: optionsEnabled,
              onSelected: (value) => session.edit((settings) => settings.scheduler = value),
            ),
          ]),
          const SizedBox(height: 14),
          if (compact) ...[
            LabeledSlider(
              label: 'Steps',
              value: settings.steps.toDouble(),
              min: 1,
              max: 150,
              divisions: 149,
              format: (value) => value.round().toString(),
              onChanged: (value) => session.edit((settings) => settings.steps = value.round()),
            ),
            LabeledSlider(
              label: 'CFG scale',
              value: settings.cfgScale,
              min: 1,
              max: 20,
              divisions: 38,
              format: (value) => NumberField.format(value, 1),
              onChanged: (value) => session.edit((settings) => settings.cfgScale = (value * 2).round() / 2),
            ),
          ] else
            Row(
              children: [
                Expanded(
                  child: NumberField(
                    label: 'Steps',
                    value: settings.steps,
                    min: 1,
                    max: 150,
                    onChanged: (value) => session.edit((settings) => settings.steps = (value ?? 20).toInt()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: NumberField(
                    label: 'CFG scale',
                    value: settings.cfgScale,
                    min: 1,
                    max: 30,
                    step: 0.5,
                    decimals: 2,
                    onChanged: (value) => session.edit((settings) => settings.cfgScale = (value ?? 7).toDouble()),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 14),
          _SizeEditor(session: session, compact: compact),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: NumberField(
                  label: 'Seed',
                  hint: '-1 = random',
                  value: settings.seed,
                  min: -1,
                  max: 9007199254740991,
                  showSteppers: false,
                  onChanged: (value) => session.edit((settings) => settings.seed = (value ?? -1).toInt()),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Random seed (-1)',
                onPressed: () => session.edit((settings) => settings.seed = -1),
                icon: const Icon(Icons.casino_outlined),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SizeEditor extends StatelessWidget {
  const _SizeEditor({required this.session, required this.compact});

  final ProjectSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final settings = session.settings;
    final fields = Row(
      children: [
        Expanded(
          child: NumberField(
            label: 'Width',
            value: settings.width,
            min: 64,
            max: 4096,
            step: 64,
            onChanged: (value) => session.edit((settings) => settings.width = (value ?? 512).toInt()),
          ),
        ),
        IconButton(
          tooltip: 'Swap width and height',
          onPressed: () => session.edit((settings) {
            final width = settings.width;
            settings
              ..width = settings.height
              ..height = width;
          }),
          icon: const Icon(Icons.swap_horiz),
        ),
        Expanded(
          child: NumberField(
            label: 'Height',
            value: settings.height,
            min: 64,
            max: 4096,
            step: 64,
            onChanged: (value) => session.edit((settings) => settings.height = (value ?? 512).toInt()),
          ),
        ),
        if (!compact)
          PopupMenuButton<(int, int)>(
            tooltip: 'Size presets',
            icon: const Icon(Icons.aspect_ratio),
            itemBuilder: (context) => [
              for (final preset in sizePresets)
                PopupMenuItem(value: preset, child: Text('${preset.$1} × ${preset.$2}  ${_ratioLabel(preset)}')),
            ],
            onSelected: (preset) => session.edit((settings) {
              settings
                ..width = preset.$1
                ..height = preset.$2;
            }),
          ),
      ],
    );

    if (!compact) {
      return fields;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        fields,
        const SizedBox(height: 10),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: sizePresets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final preset = sizePresets[index];
              final selected = settings.width == preset.$1 && settings.height == preset.$2;
              return ChoiceChip(
                avatar: _AspectIcon(width: preset.$1, height: preset.$2, selected: selected),
                label: Text('${preset.$1}×${preset.$2}'),
                selected: selected,
                showCheckmark: false,
                onSelected: (_) => session.edit((settings) {
                  settings
                    ..width = preset.$1
                    ..height = preset.$2;
                }),
              );
            },
          ),
        ),
      ],
    );
  }

  static String _ratioLabel((int, int) preset) {
    int gcd(int a, int b) => b == 0 ? a : gcd(b, a % b);
    final divisor = gcd(preset.$1, preset.$2);
    final w = preset.$1 ~/ divisor;
    final h = preset.$2 ~/ divisor;
    return w > 20 || h > 20 ? '' : '($w:$h)';
  }
}

class _AspectIcon extends StatelessWidget {
  const _AspectIcon({required this.width, required this.height, required this.selected});

  final int width;
  final int height;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final longest = width > height ? width : height;
    final color = selected ? context.colors.onSecondaryContainer : context.colors.onSurfaceVariant;
    return SizedBox.square(
      dimension: 18,
      child: Center(
        child: Container(
          width: 16 * width / longest,
          height: 16 * height / longest,
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 1.6),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

class _HiresSection extends StatelessWidget {
  const _HiresSection({required this.session, required this.compact});

  final ProjectSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final settings = session.settings;
    final enabled = settings.enableHiresFix;
    return SectionCard(
      icon: Icons.high_quality_outlined,
      title: 'Hires.fix',
      subtitle: 'Optional second pass. Leave resize at 0 × 0 to use the scale.',
      collapsible: compact,
      initiallyExpanded: !compact,
      summary: enabled
          ? 'On · ×${NumberField.format(settings.hiresScale, 2)} · ${settings.hiresUpscaler} · denoise ${NumberField.format(settings.hiresDenoisingStrength, 2)}'
          : 'Off',
      trailing: Switch(
        value: enabled,
        onChanged: (value) => session.edit((settings) => settings.enableHiresFix = value),
      ),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: enabled ? 1 : 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _responsiveRow(compact, [
              NumberField(
                label: 'Upscale by',
                value: settings.hiresScale,
                min: 1,
                max: 8,
                step: 0.25,
                decimals: 2,
                enabled: enabled,
                onChanged: (value) => session.edit((settings) => settings.hiresScale = (value ?? 2).toDouble()),
              ),
              OptionDropdown(
                label: 'Upscaler',
                value: settings.hiresUpscaler,
                options: session.hiresUpscalerOptions,
                enabled: enabled,
                onSelected: (value) => session.edit((settings) => settings.hiresUpscaler = value),
              ),
            ]),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: NumberField(
                    label: 'Resize width',
                    value: settings.hiresResizeWidth,
                    min: 0,
                    max: 8192,
                    step: 64,
                    enabled: enabled,
                    onChanged: (value) => session.edit((settings) => settings.hiresResizeWidth = (value ?? 0).toInt()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: NumberField(
                    label: 'Resize height',
                    value: settings.hiresResizeHeight,
                    min: 0,
                    max: 8192,
                    step: 64,
                    enabled: enabled,
                    onChanged: (value) => session.edit((settings) => settings.hiresResizeHeight = (value ?? 0).toInt()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            NumberField(
              label: 'Hires steps',
              hint: '0 = same as steps',
              value: settings.hiresSteps,
              min: 0,
              max: 150,
              enabled: enabled,
              onChanged: (value) => session.edit((settings) => settings.hiresSteps = (value ?? 0).toInt()),
            ),
            const SizedBox(height: 4),
            LabeledSlider(
              label: 'Denoising strength',
              value: settings.hiresDenoisingStrength,
              min: 0,
              max: 1,
              divisions: 20,
              enabled: enabled,
              format: (value) => NumberField.format(value, 2),
              onChanged: (value) =>
                  session.edit((settings) => settings.hiresDenoisingStrength = (value * 20).round() / 20),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverridesSection extends StatelessWidget {
  const _OverridesSection({required this.session, required this.compact});

  final ProjectSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final settings = session.settings;
    final prefs = context.read<AppState>().preferences;
    final defaultMode = GenerationModes.normalizeForPlatform(settings.platform, prefs.defaultGenerationMode);
    final overrides = <String>[
      if (settings.timeoutSeconds > 0) 'timeout ${settings.timeoutSeconds}s',
      if (settings.generationMode.isNotEmpty && settings.platform.isWebUi) settings.generationMode,
      if (settings.clipSkip > 0) 'CLIP skip ${settings.clipSkip}',
      if (settings.overrideGlobalCommonPrompt) 'positive addition',
      if (settings.overrideGlobalNegativePrompt) 'negative addition',
    ];
    return SectionCard(
      icon: Icons.rule,
      title: 'Project overrides',
      subtitle: 'Override the app defaults for this project only',
      collapsible: compact,
      initiallyExpanded: !compact,
      summary: overrides.isEmpty ? 'Using app defaults' : overrides.join(' · '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownMenu<String>(
            key: ValueKey(Object.hash(settings.generationMode, settings.platform, defaultMode)),
            expandedInsets: EdgeInsets.zero,
            label: const Text('Generation mode'),
            enabled: settings.platform.isWebUi,
            initialSelection: settings.platform.isComfyUi ? GenerationModes.standard : settings.generationMode,
            helperText: GenerationModes.describe(session.effectiveGenerationMode),
            dropdownMenuEntries: [
              if (settings.platform.isWebUi) DropdownMenuEntry(value: '', label: 'Use app default ($defaultMode)'),
              for (final mode in GenerationModes.optionsFor(settings.platform))
                DropdownMenuEntry(value: mode, label: mode),
            ],
            onSelected: (value) => session.edit((settings) => settings.generationMode = value ?? ''),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: NumberField(
                  label: 'Timeout (seconds)',
                  hint: 'Default (${prefs.defaultTimeoutSeconds})',
                  value: settings.timeoutSeconds > 0 ? settings.timeoutSeconds : null,
                  allowEmpty: true,
                  min: 1,
                  max: 86400,
                  step: 30,
                  onChanged: (value) => session.edit((settings) => settings.timeoutSeconds = value?.toInt() ?? 0),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NumberField(
                  label: 'CLIP skip',
                  hint: 'Default (${prefs.defaultClipSkip})',
                  value: settings.clipSkip > 0 ? settings.clipSkip : null,
                  allowEmpty: true,
                  min: 1,
                  max: 24,
                  onChanged: (value) => session.edit((settings) => settings.clipSkip = value?.toInt() ?? 0),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Override global positive addition'),
            subtitle: Text(
              prefs.globalCommonPrompt.isEmpty ? 'The app has no global addition' : prefs.globalCommonPrompt,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            value: settings.overrideGlobalCommonPrompt,
            onChanged: (value) => session.edit((settings) => settings.overrideGlobalCommonPrompt = value),
          ),
          if (settings.overrideGlobalCommonPrompt)
            PromptField(
              hint: 'Leave blank to use no global positive addition for this project.',
              value: settings.globalCommonPromptOverride,
              minLines: 2,
              onChanged: (value) => session.edit((settings) => settings.globalCommonPromptOverride = value),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Override global negative addition'),
            subtitle: Text(
              prefs.globalNegativePrompt.isEmpty ? 'The app has no global addition' : prefs.globalNegativePrompt,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            value: settings.overrideGlobalNegativePrompt,
            onChanged: (value) => session.edit((settings) => settings.overrideGlobalNegativePrompt = value),
          ),
          if (settings.overrideGlobalNegativePrompt)
            PromptField(
              hint: 'Leave blank to use no global negative addition for this project.',
              value: settings.globalNegativePromptOverride,
              minLines: 2,
              onChanged: (value) => session.edit((settings) => settings.globalNegativePromptOverride = value),
            ),
        ],
      ),
    );
  }
}

Widget _responsiveRow(bool compact, List<Widget> children) {
  if (compact) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const SizedBox(height: 12),
          children[index],
        ],
      ],
    );
  }

  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var index = 0; index < children.length; index++) ...[
        if (index > 0) const SizedBox(width: 12),
        Expanded(child: children[index]),
      ],
    ],
  );
}

/// A searchable dropdown over a server-provided option list.
class OptionDropdown extends StatelessWidget {
  const OptionDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
    this.enabled = true,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DropdownMenu<String>(
      key: ValueKey(Object.hash(value, options.length, options.isEmpty ? '' : options.first)),
      expandedInsets: EdgeInsets.zero,
      label: Text(label),
      enabled: enabled,
      enableFilter: true,
      requestFocusOnTap: true,
      menuHeight: 360,
      initialSelection: value,
      dropdownMenuEntries: [for (final option in options) DropdownMenuEntry(value: option, label: option)],
      onSelected: (selected) {
        if (selected != null && selected != value) {
          onSelected(selected);
        }
      },
    );
  }
}

class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.format,
    this.divisions,
    this.enabled = true,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final bool enabled;
  final String Function(double value) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(min, max).toDouble();
    return Row(
      children: [
        SizedBox(width: 118, child: Text(label, style: context.text.labelLarge)),
        Expanded(
          child: Slider(
            value: clamped,
            min: min,
            max: max,
            divisions: divisions,
            label: format(clamped),
            onChanged: enabled ? onChanged : null,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(format(value), textAlign: TextAlign.end, style: context.text.titleSmall),
        ),
      ],
    );
  }
}
