import 'package:flutter/material.dart';

import '../../state/cell_model.dart';
import '../../state/project_session.dart';
import '../actions.dart';
import '../cell_detail/cell_detail_page.dart';
import '../common/source_image.dart';
import '../dialogs/cell_dialogs.dart';
import '../layout.dart';
import '../platform_actions.dart';

enum CellMenuAction {
  details,
  openExternally,
  rename,
  overrides,
  chooseSource,
  useProjectSource,
  openFolder,
  copy,
  regenerate,
  remove,
}

List<PopupMenuEntry<CellMenuAction>> buildCellMenuItems(ProjectSession session, CellModel cell) => [
  PopupMenuItem(
    value: CellMenuAction.details,
    enabled: cell.hasImage,
    child: const ListTile(leading: Icon(Icons.photo_library_outlined), title: Text('Images & details')),
  ),
  if (PlatformInfo.isDesktop)
    PopupMenuItem(
      value: CellMenuAction.openExternally,
      enabled: cell.hasImage,
      child: const ListTile(leading: Icon(Icons.open_in_new), title: Text('Open image')),
    ),
  const PopupMenuItem(
    value: CellMenuAction.rename,
    child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Rename')),
  ),
  PopupMenuItem(
    value: CellMenuAction.overrides,
    child: ListTile(
      leading: const Icon(Icons.tune),
      title: Text(session.isImg2Img ? 'Edit source & overrides' : 'Edit overrides'),
    ),
  ),
  if (session.isImg2Img) ...[
    const PopupMenuItem(
      value: CellMenuAction.chooseSource,
      child: ListTile(leading: Icon(Icons.add_photo_alternate_outlined), title: Text('Choose source image…')),
    ),
    if (cell.sourceImagePath != null)
      const PopupMenuItem(
        value: CellMenuAction.useProjectSource,
        child: ListTile(leading: Icon(Icons.layers_clear_outlined), title: Text('Use project source image')),
      ),
  ],
  if (PlatformInfo.canOpenFolders)
    const PopupMenuItem(
      value: CellMenuAction.openFolder,
      child: ListTile(leading: Icon(Icons.folder_open_outlined), title: Text('Open folder')),
    ),
  const PopupMenuDivider(),
  const PopupMenuItem(
    value: CellMenuAction.copy,
    child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Duplicate')),
  ),
  const PopupMenuItem(
    value: CellMenuAction.regenerate,
    child: ListTile(leading: Icon(Icons.refresh), title: Text('Regenerate')),
  ),
  const PopupMenuItem(
    value: CellMenuAction.remove,
    child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Remove')),
  ),
];

Future<void> runCellMenuAction(
  BuildContext context,
  ProjectSession session,
  CellModel cell,
  CellMenuAction action,
) async {
  switch (action) {
    case CellMenuAction.details:
      await openCellDetail(context, session, cell);
    case CellMenuAction.openExternally:
      final path = cell.displayImagePath;
      if (path != null) {
        await PlatformActions.openFile(path);
      }
    case CellMenuAction.rename:
      await ProjectActions.renameCell(context, cell);
    case CellMenuAction.overrides:
      await showCellOverridesDialog(context, session, cell);
    case CellMenuAction.chooseSource:
      await chooseCellSourceImage(context, session, cell);
    case CellMenuAction.useProjectSource:
      await session.setCellSourceImage(cell, null);
    case CellMenuAction.openFolder:
      await ProjectActions.openFolder(context, session.cellFolder(cell));
    case CellMenuAction.copy:
      session.copyCell(cell);
    case CellMenuAction.regenerate:
      session.regenerate(cell);
    case CellMenuAction.remove:
      await ProjectActions.removeCells(context, session, [cell]);
  }
}

Future<void> showCellContextMenu(
  BuildContext context,
  ProjectSession session,
  CellModel cell,
  Offset globalPosition,
) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final action = await showMenu<CellMenuAction>(
    context: context,
    position: RelativeRect.fromRect(globalPosition & const Size(1, 1), Offset.zero & overlay.size),
    items: buildCellMenuItems(session, cell),
  );
  if (action != null && context.mounted) {
    await runCellMenuAction(context, session, cell, action);
  }
}

class CellMenuButton extends StatelessWidget {
  const CellMenuButton({super.key, required this.session, required this.cell});

  final ProjectSession session;
  final CellModel cell;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<CellMenuAction>(
      tooltip: 'Cell actions',
      itemBuilder: (_) => buildCellMenuItems(session, cell),
      onSelected: (action) => runCellMenuAction(context, session, cell, action),
    );
  }
}
