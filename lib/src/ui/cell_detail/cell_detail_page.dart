import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/sd_client.dart';
import '../../core/image_timestamps.dart';
import '../../models/img2img.dart';
import '../../state/app_state.dart';
import '../../state/cell_gallery.dart';
import '../../state/cell_model.dart';
import '../../state/project_session.dart';
import '../common/cell_image.dart';
import '../common/dialogs.dart';
import '../layout.dart';
import '../platform_actions.dart';
import '../theme.dart';
import '../versus/versus_page.dart';
import 'metadata_panel.dart';

Future<void> openCellDetail(BuildContext context, ProjectSession session, CellModel cell) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CellDetailPage(session: session, cell: cell),
    ),
  );
}

/// Image history of a cell: pick the representative image, inspect metadata, save, delete or start a
/// Versus tournament between selected images.
class CellDetailPage extends StatefulWidget {
  const CellDetailPage({super.key, required this.session, required this.cell});

  final ProjectSession session;
  final CellModel cell;

  @override
  State<CellDetailPage> createState() => _CellDetailPageState();
}

class _CellDetailPageState extends State<CellDetailPage> {
  late final CellGallery _gallery = CellGallery(widget.session, widget.cell);

  @override
  void initState() {
    super.initState();
    unawaited(_gallery.load());
  }

  @override
  void dispose() {
    _gallery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _gallery,
      builder: (context, _) => WindowClass.of(context).usesMobileLayout
          ? _MobileCellDetail(gallery: _gallery)
          : _DesktopCellDetail(gallery: _gallery),
    );
  }
}

/// Actions shared by both layouts.
class _GalleryActions {
  _GalleryActions(this.context, this.gallery);

  final BuildContext context;
  final CellGallery gallery;

  AppState get _app => context.read<AppState>();

  bool get canVersus => gallery.selectedCount >= 2;

  Future<void> delete() async {
    final count = gallery.selectedCount;
    if (count == 0) {
      return;
    }

    final confirmed = await showConfirmDialog(
      context,
      title: count == 1 ? 'Delete image' : 'Delete $count images',
      message: 'The selected image file${count == 1 ? '' : 's'} will be deleted from the project folder.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed) {
      await gallery.deleteSelected();
    }
  }

  Future<void> save() async {
    try {
      final message = await PlatformActions.saveImages(gallery.selectedImages.map((image) => image.path).toList());
      if (message != null) {
        _app.messenger.success(message);
      }
    } catch (error) {
      _app.messenger.error('Saving failed: ${SdClient.describeError(error)}');
    }
  }

  Future<void> share() async {
    try {
      await PlatformActions.shareFiles(context, gallery.selectedImages.map((image) => image.path).toList());
    } catch (error) {
      _app.messenger.error('Sharing failed: ${SdClient.describeError(error)}');
    }
  }

  void toggleRepresentative() {
    final image = gallery.primary;
    if (image == null) {
      return;
    }

    final isRepresentative = gallery.isRepresentative(image);
    gallery.setRepresentative(isRepresentative ? null : image);
    _app.messenger.info(
      isRepresentative
          ? 'The newest image is shown for ${gallery.cell.displayName} again.'
          : 'Representative image set for ${gallery.cell.displayName}.',
    );
  }

  Future<void> versus() async {
    if (!canVersus) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VersusPage(session: gallery.session, cell: gallery.cell, images: gallery.selectedImages),
      ),
    );
  }

  Future<void> openExternally() async {
    final image = gallery.primary;
    if (image != null) {
      await PlatformActions.openFile(image.path);
    }
  }

  /// Makes the shown image the cell's own image to image source, turning image to image on first
  /// when the project still generates from text.
  Future<void> useAsSource() async {
    final image = gallery.primary;
    if (image == null) {
      return;
    }

    final session = gallery.session;
    final cell = gallery.cell;
    final messenger = _app.messenger;
    if (!session.isImg2Img) {
      final confirmed = await showConfirmDialog(
        context,
        title: 'Turn on image to image?',
        message:
            '${cell.displayName} will start from this image. The project switches to image to image; other cells '
            'use the project source image or their own.',
        confirmLabel: 'Turn on',
      );
      if (!confirmed) {
        return;
      }

      session.setGenerationType(GenerationType.img2img);
    }

    try {
      await session.setCellSourceImage(cell, image.path);
      messenger.success('${cell.displayName} now starts from this image.');
    } catch (error) {
      messenger.error('Could not use the image as source: ${SdClient.describeError(error)}');
    }
  }
}

// -------------------------------------------------------------------------------------------------
// Desktop
// -------------------------------------------------------------------------------------------------

class _DesktopCellDetail extends StatefulWidget {
  const _DesktopCellDetail({required this.gallery});

  final CellGallery gallery;

  @override
  State<_DesktopCellDetail> createState() => _DesktopCellDetailState();
}

class _DesktopCellDetailState extends State<_DesktopCellDetail> {
  double? _galleryWidth;

  @override
  Widget build(BuildContext context) {
    final gallery = widget.gallery;
    final app = context.read<AppState>();
    final actions = _GalleryActions(context, gallery);
    final colors = context.colors;
    final primary = gallery.primary;
    _galleryWidth ??= app.preferences.cellDetailGalleryWidth.toDouble();
    final screenWidth = MediaQuery.sizeOf(context).width;
    final galleryWidth = _galleryWidth!.clamp(240.0, screenWidth * 0.55);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => gallery.step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => gallery.step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => gallery.step(1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => gallery.step(1),
        const SingleActivator(LogicalKeyboardKey.delete): actions.delete,
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): gallery.selectAll,
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): gallery.selectAll,
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(gallery.cell.displayName),
                Text(
                  gallery.selectedCount > 1
                      ? '${gallery.imageCountText} · ${gallery.selectedCount} selected'
                      : gallery.imageCountText,
                  style: context.text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: primary != null && gallery.isRepresentative(primary)
                    ? 'Stop using as representative image'
                    : 'Use as representative image',
                onPressed: primary == null ? null : actions.toggleRepresentative,
                icon: Icon(primary != null && gallery.isRepresentative(primary) ? Icons.star : Icons.star_border),
              ),
              IconButton(
                tooltip: 'Use as source image (image to image)',
                onPressed: primary == null ? null : actions.useAsSource,
                icon: const Icon(Icons.photo_filter_outlined),
              ),
              IconButton(
                tooltip: 'Open image',
                onPressed: primary == null ? null : actions.openExternally,
                icon: const Icon(Icons.open_in_new),
              ),
              IconButton(
                tooltip: 'Save selected',
                onPressed: gallery.selectedCount == 0 ? null : actions.save,
                icon: const Icon(Icons.save_alt),
              ),
              IconButton(
                tooltip: 'Delete selected',
                onPressed: gallery.selectedCount == 0 ? null : actions.delete,
                icon: const Icon(Icons.delete_outline),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: actions.canVersus ? actions.versus : null,
                icon: const Icon(Icons.compare),
                label: Text(actions.canVersus ? 'Versus (${gallery.selectedCount})' : 'Versus'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => gallery.session.regenerate(gallery.cell),
                icon: const Icon(Icons.refresh),
                label: const Text('Regenerate'),
              ),
              const SizedBox(width: 16),
            ],
          ),
          body: gallery.isLoading
              ? const Center(child: CircularProgressIndicator())
              : !gallery.hasImages
              ? EmptyState(
                  icon: Icons.photo_library_outlined,
                  title: 'No images yet',
                  message: 'Generated images of this cell appear here.',
                  action: FilledButton.icon(
                    onPressed: () => gallery.session.regenerate(gallery.cell),
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('Generate'),
                  ),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: galleryWidth,
                      child: _GalleryGrid(gallery: gallery, actions: actions),
                    ),
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) => setState(
                          () => _galleryWidth = (galleryWidth + details.delta.dx).clamp(240.0, screenWidth * 0.55),
                        ),
                        onHorizontalDragEnd: (_) =>
                            app.updatePreferences((prefs) => prefs.cellDetailGalleryWidth = _galleryWidth!.round()),
                        child: SizedBox(
                          width: 12,
                          child: Center(child: VerticalDivider(width: 1, color: colors.outlineVariant)),
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final preview = _Preview(gallery: gallery);
                          final details = MetadataPanel(gallery: gallery);
                          if (constraints.maxWidth >= 900) {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: preview),
                                SizedBox(
                                  width: 400,
                                  child: ColoredBox(color: colors.surfaceContainerLow, child: details),
                                ),
                              ],
                            );
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(flex: 3, child: preview),
                              Expanded(
                                flex: 2,
                                child: ColoredBox(color: colors.surfaceContainerLow, child: details),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.gallery});

  final CellGallery gallery;

  @override
  Widget build(BuildContext context) {
    final image = gallery.primary;
    if (image == null) {
      return const ImagePlaceholder(label: 'Select an image');
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: InteractiveViewer(
        key: ValueKey(image.path),
        maxScale: 8,
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: FileThumbnail(path: image.path, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

class _GalleryGrid extends StatefulWidget {
  const _GalleryGrid({required this.gallery, required this.actions});

  final CellGallery gallery;
  final _GalleryActions actions;

  @override
  State<_GalleryGrid> createState() => _GalleryGridState();
}

class _GalleryGridState extends State<_GalleryGrid> {
  // Modifier keys are read when the pointer goes down: by the time a tap is recognized the user
  // may already have released Ctrl or Shift.
  bool _toggleModifier = false;
  bool _rangeModifier = false;

  // Double clicks are detected by hand so single clicks select immediately instead of waiting for
  // the double-tap timeout.
  String? _lastTapPath;
  DateTime _lastTapTime = DateTime.fromMillisecondsSinceEpoch(0);

  void _captureModifiers(PointerDownEvent event) {
    final keyboard = HardwareKeyboard.instance;
    _toggleModifier = keyboard.isControlPressed || keyboard.isMetaPressed;
    _rangeModifier = keyboard.isShiftPressed;
  }

  void _handleTap(CellImage image) {
    final now = DateTime.now();
    final isDoubleClick =
        !_toggleModifier &&
        !_rangeModifier &&
        _lastTapPath == image.path &&
        now.difference(_lastTapTime) <= kDoubleTapTimeout;
    _lastTapPath = image.path;
    _lastTapTime = now;
    if (isDoubleClick) {
      _lastTapPath = null;
      unawaited(PlatformActions.openFile(image.path));
      return;
    }

    widget.gallery.select(image, toggle: _toggleModifier, range: _rangeModifier);
  }

  @override
  Widget build(BuildContext context) {
    final gallery = widget.gallery;
    return Listener(
      onPointerDown: _captureModifiers,
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 160,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: gallery.images.length,
        itemBuilder: (context, index) {
          final image = gallery.images[index];
          return _GalleryTile(
            gallery: gallery,
            image: image,
            onTap: () => _handleTap(image),
            onToggle: () => gallery.select(image, toggle: true),
          );
        },
      ),
    );
  }
}

/// A gallery thumbnail. On pointer devices a check button appears on hover so several images can
/// be selected without modifier keys; [onToggle] enables that button.
class _GalleryTile extends StatefulWidget {
  const _GalleryTile({required this.gallery, required this.image, required this.onTap, this.onToggle});

  final CellGallery gallery;
  final CellImage image;
  final VoidCallback onTap;
  final VoidCallback? onToggle;

  @override
  State<_GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<_GalleryTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final gallery = widget.gallery;
    final image = widget.image;
    final selected = gallery.isSelected(image);
    final isPrimary = gallery.primary?.path == image.path;
    final showCheck = widget.onToggle != null && (_hovered || gallery.selectedCount > 1);
    return Tooltip(
      message: '${image.fileName}\n${ImageTimestamps.format(image.createdAt)}',
      waitDuration: const Duration(milliseconds: 800),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.all(selected ? 4 : 0),
            decoration: BoxDecoration(
              color: selected ? colors.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isPrimary ? colors.primary : Colors.transparent, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FileThumbnail(path: image.path, decodeWidth: 160),
                  if (gallery.isRepresentative(image))
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _Badge(icon: Icons.star, color: colors.tertiary, foreground: colors.onTertiary),
                    ),
                  if (showCheck)
                    Positioned(
                      right: 2,
                      top: 2,
                      child: _SelectToggle(selected: selected, onPressed: widget.onToggle!),
                    )
                  else if (selected)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: _Badge(icon: Icons.check, color: colors.primary, foreground: colors.onPrimary),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectToggle extends StatelessWidget {
  const _SelectToggle({required this.selected, required this.onPressed});

  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return IconButton(
      tooltip: selected ? 'Deselect' : 'Add to selection',
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: selected ? colors.primary : colors.surface.withValues(alpha: 0.8),
        foregroundColor: selected ? colors.onPrimary : colors.onSurfaceVariant,
        minimumSize: const Size.square(28),
        fixedSize: const Size.square(28),
        padding: EdgeInsets.zero,
      ),
      onPressed: onPressed,
      icon: Icon(selected ? Icons.check : Icons.circle_outlined, size: 16),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color, required this.foreground});

  final IconData icon;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Icon(icon, size: 14, color: foreground),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Mobile: immersive swipe viewer with a details sheet, plus a grid for multi-selection
// -------------------------------------------------------------------------------------------------

class _MobileCellDetail extends StatefulWidget {
  const _MobileCellDetail({required this.gallery});

  final CellGallery gallery;

  @override
  State<_MobileCellDetail> createState() => _MobileCellDetailState();
}

class _MobileCellDetailState extends State<_MobileCellDetail> {
  PageController? _pages;
  bool _selecting = false;
  bool _chromeVisible = true;

  CellGallery get _gallery => widget.gallery;

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  PageController _pageController() {
    final index = _gallery.primaryIndex < 0 ? 0 : _gallery.primaryIndex;
    final controller = _pages ??= PageController(initialPage: index);
    if (controller.hasClients && controller.page?.round() != index && !controller.position.isScrollingNotifier.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (controller.hasClients && controller.page?.round() != _gallery.primaryIndex && _gallery.primaryIndex >= 0) {
          controller.jumpToPage(_gallery.primaryIndex);
        }
      });
    }

    return controller;
  }

  /// Back to the viewer, which works on the shown image only.
  void _leaveSelection() {
    setState(() => _selecting = false);
    _gallery.clearSelection();
    if (_gallery.selectedCount == 0 && _gallery.hasImages) {
      _gallery.show(_gallery.images.first);
    }
  }

  void _showDetails() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        builder: (context, scrollController) => ListenableBuilder(
          listenable: _gallery,
          builder: (context, _) => MetadataPanel(
            gallery: _gallery,
            scrollController: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final actions = _GalleryActions(context, _gallery);
    if (_gallery.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_gallery.hasImages) {
      return Scaffold(
        appBar: AppBar(title: Text(_gallery.cell.displayName)),
        body: EmptyState(
          icon: Icons.photo_library_outlined,
          title: 'No images yet',
          message: 'Generated images of this cell appear here.',
          action: FilledButton.icon(
            onPressed: () => _gallery.session.regenerate(_gallery.cell),
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Generate'),
          ),
        ),
      );
    }

    return _selecting ? _buildGrid(actions) : _buildViewer(actions);
  }

  Widget _buildViewer(_GalleryActions actions) {
    final primary = _gallery.primary ?? _gallery.images.first;
    final index = _gallery.primaryIndex < 0 ? 0 : _gallery.primaryIndex;
    final isRepresentative = _gallery.isRepresentative(primary);
    const foreground = Colors.white;
    return AnnotatedRegion(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: _chromeVisible ? Colors.black.withValues(alpha: 0.35) : Colors.transparent,
          foregroundColor: foreground,
          elevation: 0,
          toolbarOpacity: _chromeVisible ? 1 : 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_gallery.cell.displayName, style: const TextStyle(color: foreground)),
              Text(
                '${index + 1} / ${_gallery.images.length} · ${ImageTimestamps.formatShort(primary.createdAt)}',
                style: context.text.bodySmall?.copyWith(color: foreground.withValues(alpha: 0.8)),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: isRepresentative ? 'Stop using as representative image' : 'Use as representative image',
              onPressed: actions.toggleRepresentative,
              icon: Icon(
                isRepresentative ? Icons.star : Icons.star_border,
                color: isRepresentative ? Colors.amber : foreground,
              ),
            ),
            IconButton(
              tooltip: 'Use as source image (image to image)',
              onPressed: actions.useAsSource,
              icon: const Icon(Icons.photo_filter_outlined, color: foreground),
            ),
            IconButton(
              tooltip: 'Select images',
              onPressed: () => setState(() => _selecting = true),
              icon: const Icon(Icons.checklist),
            ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _chromeVisible = !_chromeVisible),
                child: PageView.builder(
                  controller: _pageController(),
                  itemCount: _gallery.images.length,
                  onPageChanged: (page) => _gallery.show(_gallery.images[page]),
                  itemBuilder: (context, page) {
                    final image = _gallery.images[page];
                    return InteractiveViewer(
                      maxScale: 6,
                      child: Center(
                        child: page == index && identical(primary, image)
                            ? Hero(
                                tag: 'cell-image-${_gallery.cell.id}',
                                child: FileThumbnail(path: image.path, fit: BoxFit.contain),
                              )
                            : FileThumbnail(path: image.path, fit: BoxFit.contain),
                      ),
                    );
                  },
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              left: 0,
              right: 0,
              bottom: _chromeVisible ? 0 : -220,
              child: _ViewerBottomBar(gallery: _gallery, actions: actions, onDetails: _showDetails),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(_GalleryActions actions) {
    final count = _gallery.selectedCount;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _leaveSelection();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(tooltip: 'Done', onPressed: _leaveSelection, icon: const Icon(Icons.close)),
          title: Text(count == 0 ? 'Select images' : '$count selected'),
          actions: [
            IconButton(tooltip: 'Select all', onPressed: _gallery.selectAll, icon: const Icon(Icons.select_all)),
            if (PlatformInfo.canShareFiles)
              IconButton(
                tooltip: 'Share',
                onPressed: count == 0 ? null : actions.share,
                icon: const Icon(Icons.share_outlined),
              ),
            IconButton(
              tooltip: 'Delete',
              onPressed: count == 0 ? null : actions.delete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        body: GridView.builder(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 120),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: _gallery.images.length,
          itemBuilder: (context, index) {
            final image = _gallery.images[index];
            return _GalleryTile(gallery: _gallery, image: image, onTap: () => _gallery.select(image, toggle: true));
          },
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: count == 0 ? null : actions.save,
                    icon: const Icon(Icons.download),
                    label: Text(PlatformInfo.canSaveToGallery ? 'Save to Photos' : 'Save'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: actions.canVersus ? actions.versus : null,
                    icon: const Icon(Icons.compare),
                    label: Text(actions.canVersus ? 'Versus ($count)' : 'Versus'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewerBottomBar extends StatelessWidget {
  const _ViewerBottomBar({required this.gallery, required this.actions, required this.onDetails});

  final CellGallery gallery;
  final _GalleryActions actions;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    const foreground = Colors.white;
    final primaryPath = gallery.primary?.path;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.85), Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 64,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  scrollDirection: Axis.horizontal,
                  itemCount: gallery.images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final image = gallery.images[index];
                    final current = image.path == primaryPath;
                    return GestureDetector(
                      onTap: () => gallery.show(image),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: current ? 64 : 52,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: current ? foreground : Colors.transparent, width: 2),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Opacity(
                            opacity: current ? 1 : 0.65,
                            child: FileThumbnail(path: image.path, decodeWidth: 64),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ViewerAction(icon: Icons.info_outline, label: 'Details', onPressed: onDetails),
                  _ViewerAction(icon: Icons.download, label: 'Save', onPressed: actions.save),
                  if (PlatformInfo.canShareFiles)
                    _ViewerAction(icon: Icons.share_outlined, label: 'Share', onPressed: actions.share),
                  _ViewerAction(
                    icon: Icons.refresh,
                    label: 'Again',
                    onPressed: () {
                      gallery.session.regenerate(gallery.cell);
                      context.read<AppState>().messenger.info('Queued ${gallery.cell.displayName} again.');
                    },
                  ),
                  _ViewerAction(icon: Icons.delete_outline, label: 'Delete', onPressed: actions.delete),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewerAction extends StatelessWidget {
  const _ViewerAction({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(height: 4),
            Text(label, style: context.text.labelSmall?.copyWith(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
