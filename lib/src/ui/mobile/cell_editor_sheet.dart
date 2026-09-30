import 'package:flutter/material.dart';

import '../../generation/generation_runner.dart';
import '../../state/cell_model.dart';
import '../../state/project_session.dart';
import '../actions.dart';
import '../cell_detail/cell_detail_page.dart';
import '../common/cell_image.dart';
import '../common/number_field.dart';
import '../common/prompt_field.dart';
import '../common/source_image.dart';
import '../dialogs/cell_dialogs.dart';
import '../theme.dart';

/// Full-height editor for one cell on phones: name, source image (image to image), prompt with
/// suggestion chips, overrides, a preview of the exact prompt that will be sent, and quick actions.
Future<void> showCellEditor(BuildContext context, ProjectSession session, CellModel cell, {bool focusPrompt = false}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _CellEditor(session: session, cell: cell, focusPrompt: focusPrompt),
    ),
  );
}

class _CellEditor extends StatefulWidget {
  const _CellEditor({required this.session, required this.cell, required this.focusPrompt});

  final ProjectSession session;
  final CellModel cell;
  final bool focusPrompt;

  @override
  State<_CellEditor> createState() => _CellEditorState();
}

class _CellEditorState extends State<_CellEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.cell.displayName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final index = widget.session.cells.indexOf(widget.cell);
    widget.session.moveCell(index, index + delta);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final cell = widget.cell;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: Listenable.merge([session, cell]),
      builder: (context, _) {
        final index = session.cells.indexOf(cell);
        if (index < 0) {
          return const SizedBox(height: 120, child: Center(child: Text('This cell was removed.')));
        }

        final request = GenerationRunner.buildRequest(session.createContext([cell.snapshot()], 1), cell.snapshot());
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (cell.hasImage)
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          openCellDetail(context, session, cell);
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: SizedBox.square(
                            dimension: 56,
                            child: FileThumbnail(path: cell.displayImagePath!, decodeWidth: 56),
                          ),
                        ),
                      )
                    else
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: colors.secondaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Center(child: Text('${index + 1}', style: context.text.titleLarge)),
                      ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: TextField(
                        controller: _name,
                        style: context.text.titleLarge,
                        decoration: const InputDecoration(
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          hintText: 'Cell name',
                          contentPadding: EdgeInsets.zero,
                        ),
                        onChanged: (value) => cell.name = value,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Move earlier',
                      onPressed: index == 0 ? null : () => _move(-1),
                      icon: const Icon(Icons.arrow_upward),
                    ),
                    IconButton(
                      tooltip: 'Move later',
                      onPressed: index == session.cells.length - 1 ? null : () => _move(1),
                      icon: const Icon(Icons.arrow_downward),
                    ),
                  ],
                ),
                if (session.isImg2Img) ...[
                  const SizedBox(height: 16),
                  CellSourcePanel(session: session, cell: cell, thumbnailSize: 96),
                ],
                const SizedBox(height: 16),
                PromptField(
                  label: 'Prompt',
                  hint: 'What this cell adds to the project prompt',
                  value: cell.prompt,
                  minLines: 4,
                  maxLines: 12,
                  autofocus: widget.focusPrompt,
                  style: SuggestionStyle.chips,
                  onChanged: (value) => cell.prompt = value,
                ),
                const SizedBox(height: 8),
                _ExpansionCard(
                  icon: Icons.tune,
                  title: 'Overrides',
                  subtitle: cell.overrideLabels.isEmpty ? 'Uses the project settings' : cell.overrideLabels.join(' · '),
                  child: CellOverridesForm(session: session, cell: cell, showSource: false),
                ),
                const SizedBox(height: 8),
                _ExpansionCard(
                  icon: Icons.visibility_outlined,
                  title: 'Prompt preview',
                  subtitle: 'Exactly what is sent to ${session.settings.platform.label}',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Positive', style: context.text.labelLarge),
                      const SizedBox(height: 4),
                      SelectableText(request.prompt.isEmpty ? '—' : request.prompt, style: context.text.bodySmall),
                      const SizedBox(height: 12),
                      Text('Negative', style: context.text.labelLarge),
                      const SizedBox(height: 4),
                      SelectableText(request.negativePrompt ?? '—', style: context.text.bodySmall),
                      const SizedBox(height: 12),
                      Text(
                        '${session.isImg2Img ? 'img2img · denoise ${NumberField.format(request.denoisingStrength, 2)} · '
                                  '${request.resizeMode} · ' : ''}'
                        '${request.steps} steps · CFG ${request.cfgScale} · ${_sizeText(session, cell, request.width, request.height)} · '
                        '${request.samplerName ?? ''} ${request.scheduler ?? ''}',
                        style: context.text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    IconButton.outlined(
                      tooltip: 'Remove cell',
                      onPressed: () async {
                        final navigator = Navigator.of(context);
                        await ProjectActions.removeCells(context, session, [cell]);
                        if (!session.cells.contains(cell)) {
                          navigator.pop();
                        }
                      },
                      icon: const Icon(Icons.delete_outline),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      tooltip: 'Duplicate cell',
                      onPressed: () {
                        session.copyCell(cell);
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.copy_all_outlined),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        onPressed: () {
                          session.regenerate(cell);
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.auto_awesome),
                        label: const Text('Generate this cell'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The preview request has no source image, so a size taken from the source is described instead.
String _sizeText(ProjectSession session, CellModel cell, int width, int height) {
  final sourceSized = session.isImg2Img && session.settings.useSourceImageSize;
  if (!sourceSized || (cell.overrideWidth != null && cell.overrideHeight != null)) {
    return '$width×$height';
  }

  return cell.overrideWidth == null && cell.overrideHeight == null ? 'source size' : 'source size with overrides';
}

class _ExpansionCard extends StatelessWidget {
  const _ExpansionCard({required this.icon, required this.title, required this.subtitle, required this.child});

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: context.colors.surfaceContainer,
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        shape: const RoundedRectangleBorder(),
        collapsedShape: const RoundedRectangleBorder(),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [child],
      ),
    );
  }
}
