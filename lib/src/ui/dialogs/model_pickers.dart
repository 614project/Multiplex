import 'package:flutter/material.dart';

import '../../api/sd_client.dart';
import '../../models/api_platform.dart';
import '../../models/lora_selection.dart';
import '../../state/project_session.dart';
import '../common/dialogs.dart';
import '../layout.dart';
import '../theme.dart';

/// Lets the user choose a checkpoint reported by the server (or the server default).
Future<void> pickCheckpoint(BuildContext context, ProjectSession session) async {
  final result = await showAdaptiveSheet<String>(
    context,
    asSheet: WindowClass.of(context).usesMobileLayout,
    builder: (context, scrollController) => _CheckpointPicker(session: session, scrollController: scrollController),
  );
  if (result != null) {
    session.setCheckpoint(result);
  }
}

class _CheckpointPicker extends StatefulWidget {
  const _CheckpointPicker({required this.session, this.scrollController});

  final ProjectSession session;
  final ScrollController? scrollController;

  @override
  State<_CheckpointPicker> createState() => _CheckpointPickerState();
}

class _CheckpointPickerState extends State<_CheckpointPicker> {
  late Future<List<String>> _future = widget.session.fetchCheckpoints();
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final isComfy = session.settings.platform.isComfyUi;
    final current = session.settings.checkpointModel;
    final defaultLabel = isComfy ? 'Use the first available ComfyUI checkpoint' : 'Use the checkpoint WebUI has loaded';
    return _PickerScaffold(
      title: 'Select checkpoint',
      description: isComfy
          ? 'Checkpoints exposed by ComfyUI /object_info for CheckpointLoaderSimple.'
          : 'Checkpoints reported by the Stable Diffusion WebUI API. Sent as override_settings.sd_model_checkpoint.',
      searchHint: 'Filter checkpoints',
      onFilterChanged: (value) => setState(() => _filter = value.trim().toLowerCase()),
      child: FutureBuilder<List<String>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasError) {
            return _LoadError(
              message: 'Failed to load checkpoints: ${SdClient.describeError(snapshot.error!)}',
              onRetry: () => setState(() => _future = session.fetchCheckpoints()),
            );
          }

          final names = snapshot.data!
              .where((name) => _filter.isEmpty || name.toLowerCase().contains(_filter))
              .toList();
          return ListView(
            controller: widget.scrollController,
            shrinkWrap: widget.scrollController == null,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: [
              _ChoiceTile(
                title: defaultLabel,
                icon: Icons.auto_mode,
                selected: current.isEmpty,
                onTap: () => Navigator.pop(context, ''),
              ),
              if (snapshot.data!.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    isComfy
                        ? 'No checkpoints were returned from ComfyUI /object_info.'
                        : 'No checkpoints were returned from the WebUI API.',
                  ),
                ),
              for (final name in names)
                _ChoiceTile(
                  title: name,
                  icon: Icons.memory,
                  selected: name == current,
                  onTap: () => Navigator.pop(context, name),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({required this.title, required this.icon, required this.selected, required this.onTap});

  final String title;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: selected ? Icon(Icons.check_circle, color: context.colors.primary) : null,
      selected: selected,
      selectedTileColor: context.colors.secondaryContainer.withValues(alpha: 0.6),
      onTap: onTap,
    );
  }
}

/// Lets the user choose LoRAs and their weights. On ComfyUI the loader node type can be chosen too.
Future<void> pickLoras(BuildContext context, ProjectSession session) async {
  final result = await showAdaptiveSheet<(List<LoraSelection>, String?)>(
    context,
    asSheet: WindowClass.of(context).usesMobileLayout,
    maxDialogWidth: 640,
    builder: (context, scrollController) => _LoraPicker(session: session, scrollController: scrollController),
  );
  if (result != null) {
    session.setLoras(result.$1, comfyLoaderType: result.$2);
  }
}

class _LoraDraft {
  _LoraDraft(this.name, {required this.selected, required this.weight, required this.unavailable});

  final String name;
  bool selected;
  double weight;
  final bool unavailable;
}

class _LoraPicker extends StatefulWidget {
  const _LoraPicker({required this.session, this.scrollController});

  final ProjectSession session;
  final ScrollController? scrollController;

  @override
  State<_LoraPicker> createState() => _LoraPickerState();
}

class _LoraPickerState extends State<_LoraPicker> {
  late Future<LoraCatalog> _future = widget.session.fetchLoras();
  List<_LoraDraft>? _drafts;
  List<String> _loaderTypes = const [ComfyLoraLoaderTypes.loraLoader];
  late String _loaderType = ComfyLoraLoaderTypes.normalize(widget.session.settings.comfyLoraLoaderType);
  String _filter = '';

  void _buildDrafts(LoraCatalog catalog) {
    if (_drafts != null) {
      return;
    }

    final selected = {
      for (final lora in LoraSelection.normalize(widget.session.settings.selectedLoras)) lora.name.toLowerCase(): lora,
    };
    final returned = {for (final name in catalog.names) name.toLowerCase()};
    final names = <String>[
      ...selected.values.where((lora) => !returned.contains(lora.name.toLowerCase())).map((lora) => lora.name),
      ...{
        for (final name in catalog.names)
          if (name.trim().isNotEmpty) name,
      }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())),
    ];
    _drafts = [
      for (final name in names)
        _LoraDraft(
          name,
          selected: selected.containsKey(name.toLowerCase()),
          weight: selected[name.toLowerCase()]?.weight ?? 1.0,
          unavailable: !returned.contains(name.toLowerCase()),
        ),
    ];
    _loaderTypes = catalog.loaderTypes.isEmpty ? const [ComfyLoraLoaderTypes.loraLoader] : catalog.loaderTypes;
    if (!_loaderTypes.contains(_loaderType)) {
      _loaderType = _loaderTypes.first;
    }
  }

  void _apply() {
    final drafts = _drafts ?? const [];
    Navigator.pop(context, (
      [
        for (final draft in drafts.where((draft) => draft.selected))
          LoraSelection(name: draft.name, weight: LoraSelection.normalizeWeight(draft.weight)),
      ],
      widget.session.settings.platform.isComfyUi ? _loaderType : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isComfy = widget.session.settings.platform.isComfyUi;
    return _PickerScaffold(
      title: 'Select LoRAs',
      description: isComfy
          ? 'Selected LoRAs are chained into the ComfyUI workflow instead of the prompt.'
          : 'Selected LoRAs are appended to the effective positive prompt as <lora:name:weight>.',
      searchHint: 'Filter LoRAs',
      onFilterChanged: (value) => setState(() => _filter = value.trim().toLowerCase()),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _drafts == null ? null : _apply, child: const Text('Apply')),
      ],
      child: FutureBuilder<LoraCatalog>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasError) {
            return _LoadError(
              message: 'Failed to load LoRAs: ${SdClient.describeError(snapshot.error!)}',
              onRetry: () => setState(() => _future = widget.session.fetchLoras()),
            );
          }

          final hadDrafts = _drafts != null;
          _buildDrafts(snapshot.data!);
          if (!hadDrafts) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {});
              }
            });
          }

          final visible = _drafts!
              .where((draft) => _filter.isEmpty || draft.name.toLowerCase().contains(_filter))
              .toList();
          return ListView(
            controller: widget.scrollController,
            shrinkWrap: widget.scrollController == null,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: [
              if (isComfy)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: DropdownMenu<String>(
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('ComfyUI loader node'),
                    initialSelection: _loaderType,
                    dropdownMenuEntries: [for (final type in _loaderTypes) DropdownMenuEntry(value: type, label: type)],
                    onSelected: (value) => setState(() => _loaderType = value ?? _loaderType),
                  ),
                ),
              if (_drafts!.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    isComfy
                        ? 'No LoRAs were returned from ComfyUI /object_info.'
                        : 'No LoRAs were returned from the WebUI API.',
                  ),
                )
              else if (visible.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Text('No LoRAs match the current filter.')),
              for (final draft in visible) _LoraRow(draft: draft, onChanged: () => setState(() {})),
            ],
          );
        },
      ),
    );
  }
}

class _LoraRow extends StatelessWidget {
  const _LoraRow({required this.draft, required this.onChanged});

  final _LoraDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: draft.selected ? colors.secondaryContainer.withValues(alpha: 0.55) : null,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          CheckboxListTile(
            value: draft.selected,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(draft.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: draft.unavailable ? const Text('Saved, but not returned by the server') : null,
            secondary: draft.selected
                ? Text(LoraSelection.formatWeight(draft.weight), style: context.text.titleSmall)
                : null,
            onChanged: (value) {
              draft.selected = value ?? false;
              onChanged();
            },
          ),
          if (draft.selected)
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 0, 12, 8),
              child: Row(
                children: [
                  Text('Weight', style: context.text.labelMedium),
                  Expanded(
                    child: Slider(
                      value: draft.weight.clamp(-2.0, 2.0),
                      min: -2,
                      max: 2,
                      divisions: 80,
                      label: LoraSelection.formatWeight(draft.weight),
                      onChanged: (value) {
                        draft.weight = (value * 20).round() / 20;
                        onChanged();
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PickerScaffold extends StatelessWidget {
  const _PickerScaffold({
    required this.title,
    required this.description,
    required this.searchHint,
    required this.onFilterChanged,
    required this.child,
    this.actions,
  });

  final String title;
  final String description;
  final String searchHint;
  final ValueChanged<String> onFilterChanged;
  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.text.headlineSmall),
              const SizedBox(height: 4),
              Text(description, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
              const SizedBox(height: 16),
              TextField(
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: searchHint),
                onChanged: onFilterChanged,
              ),
            ],
          ),
        ),
        Flexible(child: child),
        if (actions != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, spacing: 8, children: actions!),
          ),
      ],
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, color: context.colors.error, size: 32),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
        ],
      ),
    );
  }
}
