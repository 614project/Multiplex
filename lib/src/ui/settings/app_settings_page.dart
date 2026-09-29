import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_info.dart';
import '../../models/api_platform.dart';
import '../../models/app_preferences.dart';
import '../../services/app_log.dart';
import '../../state/app_state.dart';
import '../actions.dart';
import '../common/number_field.dart';
import '../common/prompt_field.dart';
import '../common/section_card.dart';
import '../layout.dart';
import '../platform_actions.dart';
import '../theme.dart';
import '../workspace/project_settings_view.dart';

/// Whether the platform offers a dynamic (wallpaper/accent based) color scheme.
class DynamicColorSupport {
  const DynamicColorSupport({required this.available});

  final bool available;
}

Future<void> openAppSettings(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AppSettingsPage()));
}

class AppSettingsPage extends StatelessWidget {
  const AppSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final prefs = app.preferences;
    final compact = WindowClass.of(context).usesMobileLayout;
    final dynamicAvailable = context.watch<DynamicColorSupport>().available;
    void update(void Function(AppPreferences prefs) change) => app.updatePreferences(change);

    final sections = <Widget>[
      SectionCard(
        icon: Icons.palette_outlined,
        title: 'Appearance',
        subtitle: 'Applied right away and saved automatically',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('System')),
                ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
              ],
              selected: {prefs.themeMode},
              onSelectionChanged: (selection) => update((prefs) => prefs.themeMode = selection.first),
            ),
            const SizedBox(height: 12),
            if (dynamicAvailable)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Dynamic color'),
                subtitle: const Text('Use the colors of your wallpaper or system accent'),
                value: prefs.useDynamicColor,
                onChanged: (value) => update((prefs) => prefs.useDynamicColor = value),
              ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: dynamicAvailable && prefs.useDynamicColor ? 0.4 : 1,
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final (name, value) in seedColorOptions)
                    _ColorSwatch(
                      name: name,
                      color: Color(value),
                      selected: prefs.seedColor == value,
                      onTap: () => update((prefs) {
                        prefs
                          ..seedColor = value
                          ..useDynamicColor = false;
                      }),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('Cells', style: context.text.titleSmall),
            const SizedBox(height: 4),
            LabeledSlider(
              label: 'List height',
              value: prefs.listCellHeight.toDouble(),
              min: AppPreferences.minListCellHeight.toDouble(),
              max: AppPreferences.maxListCellHeight.toDouble(),
              divisions: 26,
              format: (value) => value.round().toString(),
              onChanged: (value) => update((prefs) => prefs.listCellHeight = value.round()),
            ),
            LabeledSlider(
              label: 'Icon width',
              value: prefs.gridCellWidth.toDouble(),
              min: AppPreferences.minGridCellWidth.toDouble(),
              max: AppPreferences.maxGridCellWidth.toDouble(),
              divisions: 36,
              format: (value) => value.round().toString(),
              onChanged: (value) => update((prefs) => prefs.gridCellWidth = value.round()),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text('Phone gallery columns', style: context.text.labelLarge)),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1')),
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 3, label: Text('3')),
                  ],
                  selected: {prefs.mobileCellColumns},
                  onSelectionChanged: (selection) => update((prefs) => prefs.mobileCellColumns = selection.first),
                ),
              ],
            ),
          ],
        ),
      ),
      SectionCard(
        icon: Icons.public,
        title: 'Server',
        subtitle: 'Used by every project whose own API base URL is empty',
        child: _GlobalUrlField(
          initial: prefs.globalApiBaseUrl,
          onChanged: (value) => update((prefs) => prefs.globalApiBaseUrl = value),
        ),
      ),
      SectionCard(
        icon: Icons.settings_suggest_outlined,
        title: 'Generation defaults',
        subtitle: 'Used when a project does not override them',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownMenu<String>(
              expandedInsets: EdgeInsets.zero,
              label: const Text('Default WebUI generation mode'),
              initialSelection: prefs.defaultGenerationMode,
              helperText: GenerationModes.describe(prefs.defaultGenerationMode),
              dropdownMenuEntries: [
                for (final mode in GenerationModes.all) DropdownMenuEntry(value: mode, label: mode),
              ],
              onSelected: (value) => update((prefs) => prefs.defaultGenerationMode = value ?? GenerationModes.standard),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: NumberField(
                    label: 'Timeout (seconds)',
                    value: prefs.defaultTimeoutSeconds,
                    min: 1,
                    max: 86400,
                    step: 30,
                    onChanged: (value) => update((prefs) => prefs.defaultTimeoutSeconds = (value ?? 600).toInt()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: NumberField(
                    label: 'CLIP skip',
                    value: prefs.defaultClipSkip,
                    min: 1,
                    max: 24,
                    onChanged: (value) => update((prefs) => prefs.defaultClipSkip = (value ?? 1).toInt()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            NumberField(
              label: 'Polling recovery wait (seconds)',
              value: prefs.pollingRecoveryGraceSeconds,
              min: 0,
              max: 30,
              onChanged: (value) => update((prefs) => prefs.pollingRecoveryGraceSeconds = (value ?? 4).toInt()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text(
                'When Polling mode loses the final response, keep checking the progress preview for a few more seconds '
                'and prefer a larger image if one appears.',
                style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Live preview'),
              subtitle: const Text('Poll WebUI progress to show step progress and preview images while generating'),
              value: prefs.livePreviewEnabled,
              onChanged: (value) => update((prefs) => prefs.livePreviewEnabled = value),
            ),
          ],
        ),
      ),
      SectionCard(
        icon: Icons.add_comment_outlined,
        title: 'Global prompt additions',
        subtitle: 'Prepended to every project unless a project overrides them',
        child: Column(
          children: [
            PromptField(
              label: 'Positive addition',
              value: prefs.globalCommonPrompt,
              minLines: 2,
              onChanged: (value) => update((prefs) => prefs.globalCommonPrompt = value),
            ),
            const SizedBox(height: 12),
            PromptField(
              label: 'Negative addition',
              value: prefs.globalNegativePrompt,
              minLines: 2,
              onChanged: (value) => update((prefs) => prefs.globalNegativePrompt = value),
            ),
          ],
        ),
      ),
      const _AutocompleteSection(),
      SectionCard(
        icon: Icons.drive_folder_upload_outlined,
        title: 'Projects',
        subtitle: 'JSON files are compatible with WebuiMultiflex in both directions',
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => ProjectActions.exportAll(context),
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Export all projects'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => ProjectActions.import(context),
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('Import projects'),
            ),
            if (PlatformInfo.canOpenFolders) ...[
              OutlinedButton.icon(
                onPressed: () => ProjectActions.openFolder(context, app.paths.projectsRoot),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Open projects folder'),
              ),
              if (AppLog.path != null)
                OutlinedButton.icon(
                  onPressed: () => ProjectActions.openFolder(context, app.paths.root),
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Open data folder'),
                ),
            ],
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Image.asset('assets/icon/multiplex.png', width: 48, height: 48),
            const SizedBox(height: 8),
            Text('Multiplex $appVersion', style: context.text.titleSmall),
            const SizedBox(height: 4),
            Text(
              'A Flutter and Material 3 rewrite of WebuiMultiflex · made by 614project.',
              textAlign: TextAlign.center,
              style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24, vertical: 12),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final section in sections) Padding(padding: const EdgeInsets.only(bottom: 12), child: section),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlobalUrlField extends StatefulWidget {
  const _GlobalUrlField({required this.initial, required this.onChanged});

  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<_GlobalUrlField> createState() => _GlobalUrlFieldState();
}

class _GlobalUrlFieldState extends State<_GlobalUrlField> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'Global API base URL',
        hintText: 'e.g. http://192.168.0.10:7860',
        helperText: 'Blank uses each platform default (WebUI 127.0.0.1:7860, ComfyUI 127.0.0.1:8188).',
        prefixIcon: Icon(Icons.link),
      ),
      onChanged: widget.onChanged,
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.name, required this.color, required this.selected, required this.onTap});

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: color, brightness: Theme.of(context).brightness);
    return Tooltip(
      message: name,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              colors: [scheme.primary, scheme.tertiary, scheme.secondaryContainer, scheme.primary],
            ),
            border: Border.all(color: selected ? context.colors.onSurface : Colors.transparent, width: 3),
          ),
          child: selected ? Icon(Icons.check, color: scheme.onPrimary) : null,
        ),
      ),
    );
  }
}

class _AutocompleteSection extends StatelessWidget {
  const _AutocompleteSection();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final service = app.autocomplete;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final status = service.isBusy
            ? 'Preparing tag data…'
            : service.isReady
            ? '${service.entryCount} searchable tags${service.hasCustomData ? ' (including your CSV)' : ''}'
            : service.hasLocalData
            ? 'Tag data is downloaded and loads on first use'
            : 'Tag data has not been downloaded yet';
        return SectionCard(
          icon: Icons.sell_outlined,
          title: 'Prompt autocomplete',
          subtitle: 'Suggestions after two characters. Desktop: arrows, Tab to accept, Esc to dismiss.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enable prompt autocomplete'),
                subtitle: Text(status),
                value: app.preferences.promptAutocompleteEnabled,
                onChanged: (value) => app.updatePreferences((prefs) => prefs.promptAutocompleteEnabled = value),
              ),
              if (service.isBusy) const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: service.isBusy
                        ? null
                        : () async {
                            final ok = await service.redownload(onFailure: app.messenger.error);
                            if (ok) {
                              app.messenger.success('Autocomplete data downloaded.');
                            }
                          },
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('Re-download tag data'),
                  ),
                  OutlinedButton.icon(
                    onPressed: service.isBusy
                        ? null
                        : () async {
                            final bytes = await PlatformActions.pickCsvFile();
                            if (bytes != null && await service.importCustomCsv(bytes, onFailure: app.messenger.error)) {
                              app.messenger.success('Custom autocomplete tags imported.');
                            }
                          },
                    icon: const Icon(Icons.upload_outlined),
                    label: const Text('Import CSV'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
