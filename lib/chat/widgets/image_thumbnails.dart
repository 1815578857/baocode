import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ide/ide_hover.dart';
import '../../ide/ide_menu.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../workspace/window_controls.dart';
import '../chat_models.dart';
import '../side_panel/file_link_menu.dart';
import '../side_panel/file_open.dart';
import 'hover_builder.dart';

/// Pictures attached to a message, small; a click shows one whole. With
/// [onRemove], each has a button to take it off (as in the composer).
/// One size in a message and in its editor, so editing does not resize
/// them.
class ImageThumbnails extends StatelessWidget {
  const ImageThumbnails({
    super.key,
    required this.images,
    this.onRemove,
    this.size = 48,
  });

  final List<ImageAttachment> images;
  final ValueChanged<int>? onRemove;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (i, image) in images.indexed)
          _Thumbnail(
            // A new image at this position is a new thumbnail.
            key: ObjectKey(image),
            image: image,
            size: size,
            onRemove: onRemove == null ? null : () => onRemove!(i),
          ),
      ],
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    super.key,
    required this.image,
    required this.size,
    this.onRemove,
  });

  final ImageAttachment image;
  final double size;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => Stack(
        clipBehavior: Clip.none,
        children: [
          // In a message, a right click offers its menu (see
          // fileLinkMenuAt).
          FileLinkMenuRegion(
            menu: ImageMenu(image),
            child: Listener(
              onPointerDown: (_) => PreviewPressScope._press(context),
              child: GestureDetector(
                onTap: () => showImagePreview(context, image),
                child: IdeHover(
                  message: image.name ?? '',
                  child: Container(
                    width: size,
                    height: size,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    // Over the picture, which is clipped to the same corners:
                    // under it, the picture's corners would cover its curve.
                    foregroundDecoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: hovered
                            ? AppColors.textFaint
                            : AppColors.borderStrong,
                      ),
                    ),
                    child: Image.memory(
                      image.bytes,
                      fit: BoxFit.cover,
                      cacheWidth: (size * 3).round(),
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stack) => Icon(
                        Icons.broken_image_outlined,
                        size: 16,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (onRemove case final remove? when hovered)
            Positioned(
              top: -5,
              right: -5,
              child: GestureDetector(
                onTap: remove,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceRaised,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.borderStrong),
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 11,
                    color: AppColors.text,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shows [image] whole: where the chat's files open (the side panel, the
/// IDE), as a file there (see [FileOpenScope.showImage]); else over the
/// window, where a click closes it and a right click offers [menu] (a
/// file's, say), or to copy it, as do ⌘C and Ctrl+C.
void showImagePreview(
  BuildContext context,
  ImageAttachment image, {
  ChatItemMenu? menu,
}) {
  if (FileOpenScope.find(context)?.showImage(
        image,
        name: image.name ?? context.l10n.shownImage,
      ) ??
      false) {
    return;
  }
  showDialog<void>(
    context: context,
    // Black, not the theme's: as upstream's modal backdrops.
    barrierColor: Colors.black87,
    builder: (context) => _ImagePreview(image: image, menu: menu),
  );
}

/// What a right click on an image of a message offers: to show it whole,
/// and to copy it.
class ImageMenu implements ChatItemMenu {
  const ImageMenu(this.image);

  final ImageAttachment image;

  @override
  Future<void> show(BuildContext context, Offset position) {
    final l10n = context.l10n;
    return showIdeMenu(
      context,
      position: position,
      entries: ideMenuGroups([
        [
          IdeMenuAction(
            l10n.fileLinkPreview,
            onSelected: () => showImagePreview(context, image),
          ),
        ],
        [
          IdeMenuAction(
            l10n.imageCopy,
            onSelected: () =>
                unawaited(WindowControls.writePasteboardImage(image)),
          ),
        ],
      ]),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.image, this.menu});

  final ImageAttachment image;
  final ChatItemMenu? menu;

  void _copy() => WindowControls.writePasteboardImage(image);

  Future<void> _showMenu(BuildContext context, Offset position) async {
    if (menu case final menu?) return menu.show(context, position);
    final chosen = await WindowControls.showContextMenu(position, [
      NativeMenuItem('copyImage', context.l10n.imageCopy, key: 'c'),
    ]);
    if (chosen == 'copyImage') _copy();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): _copy,
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): _copy,
      },
      child: Focus(
        autofocus: true,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: InteractiveViewer(
                maxScale: 6,
                child: GestureDetector(
                  onSecondaryTapUp: (details) =>
                      _showMenu(context, details.globalPosition),
                  child: Image.memory(image.bytes, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [child], which a click shows [image] whole from (see [showImagePreview]).
class ImagePreviewClick extends StatelessWidget {
  const ImagePreviewClick({
    super.key,
    required this.image,
    required this.child,
  });

  final ImageAttachment image;
  final Widget child;

  @override
  Widget build(BuildContext context) => PreviewClick(
    onOpen: () => showImagePreview(context, image),
    child: child,
  );
}

/// [child], a tag for something shown shortened (an image, a long paste),
/// which a click opens whole ([onOpen]). Hears the click itself rather
/// than through a gesture, so a selection of the text around it (in an
/// editor, a message) goes on as it would.
class PreviewClick extends StatefulWidget {
  const PreviewClick({super.key, required this.onOpen, required this.child});

  final VoidCallback onOpen;
  final Widget child;

  @override
  State<PreviewClick> createState() => _PreviewClickState();
}

class _PreviewClickState extends State<PreviewClick> {
  /// Where a primary press went down; null for other presses.
  Offset? _pressedAt;

  void _handleDown(PointerDownEvent event) {
    final primary =
        event.kind != PointerDeviceKind.mouse ||
        event.buttons == kPrimaryMouseButton;
    // Shift extends a selection.
    if (!primary || HardwareKeyboard.instance.isShiftPressed) return;
    _pressedAt = event.position;
    PreviewPressScope._press(context);
  }

  void _handleUp(PointerUpEvent event) {
    final pressedAt = _pressedAt;
    _pressedAt = null;
    // A click, not the end of a drag selection.
    if (pressedAt == null ||
        (event.position - pressedAt).distance > kTouchSlop) {
      return;
    }
    widget.onOpen();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: Listener(
      onPointerDown: _handleDown,
      onPointerUp: _handleUp,
      onPointerCancel: (_) => _pressedAt = null,
      child: widget.child,
    ),
  );
}

/// Tells what is around images and tags a press on one of them (which opens
/// it whole, see [PreviewClick]) from a press on the rest of it: [onPress]
/// hears it first.
class PreviewPressScope extends InheritedWidget {
  const PreviewPressScope({
    super.key,
    required this.onPress,
    required super.child,
  });

  final VoidCallback onPress;

  static void _press(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PreviewPressScope>()?.onPress();

  @override
  bool updateShouldNotify(PreviewPressScope oldWidget) => false;
}
