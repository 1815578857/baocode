import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/composer/composer_files.dart';
import '../chat/widgets/hover_builder.dart';
import '../ide/ide_hover.dart';
import '../l10n/l10n.dart';
import '../remote/remote_location.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'stash_actions.dart';
import 'stash_controller.dart';
import 'stash_note.dart';

/// A project's backlog, in the agent window's side panel: the stashes
/// about it not done yet, those being carried out first. Each can be
/// dragged into the message, or carried out in a new conversation.
class StashBacklog extends StatefulWidget {
  const StashBacklog({
    super.key,
    required this.controller,
    required this.project,
  });

  final StashController controller;

  /// The project's path, as the workspace has it.
  final String project;

  @override
  State<StashBacklog> createState() => _StashBacklogState();
}

class _StashBacklogState extends State<StashBacklog> {
  bool _showDone = false;

  bool _about(StashNote note) {
    final project = note.project;
    if (project == null) return false;
    return project == widget.project ||
        RemoteLocation.pathOf(project) ==
                RemoteLocation.pathOf(widget.project) &&
            RemoteLocation.hostOf(project) ==
                RemoteLocation.hostOf(widget.project);
  }

  static int _rank(StashNote note) => switch (note.status) {
    StashStatus.implementing => 0,
    StashStatus.requirement => 1,
    StashStatus.collected => 2,
    StashStatus.done => 3,
  };

  Future<void> _new() async {
    final controller = widget.controller;
    final note = await controller.store.create(project: widget.project);
    await controller.open(note.id);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.store]),
      builder: (context, _) {
        final notes = controller.store.notes
            .where((note) => !note.isBlank && _about(note))
            .toList();
        final open =
            notes.where((note) => note.status != StashStatus.done).toList()
              ..sort((a, b) {
                if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
                final rank = _rank(a).compareTo(_rank(b));
                return rank != 0 ? rank : b.updated.compareTo(a.updated);
              });
        final done = notes
            .where((note) => note.status == StashStatus.done)
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
              child: Row(
                children: [
                  Text(
                    l10n.stashBacklog,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${open.length}',
                    style: TextStyle(
                      color: AppColors.textFaint,
                      fontSize: 11.5,
                    ),
                  ),
                  const Spacer(),
                  _IconAction(
                    icon: Codicons.add,
                    tooltip: l10n.stashNewTooltip,
                    onTap: () => unawaited(_new()),
                  ),
                ],
              ),
            ),
            Expanded(
              child: open.isEmpty && done.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          l10n.stashBacklogEmpty,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textFaint,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
                      children: [
                        for (final note in open) _row(note),
                        if (done.isNotEmpty) ...[
                          HoverBuilder(
                            cursor: SystemMouseCursors.click,
                            builder: (context, hovered) => GestureDetector(
                              onTap: () =>
                                  setState(() => _showDone = !_showDone),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
                                child: Row(
                                  children: [
                                    Icon(
                                      _showDone
                                          ? Codicons.chevronDown
                                          : Codicons.chevronRight,
                                      size: 12,
                                      color: AppColors.textFaint,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${l10n.stashGroupDone} ${done.length}',
                                      style: TextStyle(
                                        color: AppColors.textFaint,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (_showDone)
                            for (final note in done)
                              Opacity(opacity: .55, child: _row(note)),
                        ],
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _row(StashNote note) {
    final controller = widget.controller;
    final l10n = context.l10n;
    final row = HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: () {
          if (controller.showPage case final show?) {
            show(note.id);
          } else {
            unawaited(controller.open(note.id));
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: hovered ? AppColors.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  switch (note.status) {
                    StashStatus.collected => Codicons.inbox,
                    StashStatus.requirement => Codicons.checklist,
                    StashStatus.implementing => Codicons.play,
                    StashStatus.done => Codicons.check,
                  },
                  size: 12,
                  color: note.status == StashStatus.implementing
                      ? themeColors['textLink.foreground']
                      : AppColors.textMuted,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${note.tag} ${note.displayTitle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppColors.text, fontSize: 12.5),
                    ),
                    if (note.summary.isNotEmpty)
                      Text(
                        note.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textFaint,
                          fontSize: 11.5,
                        ),
                      ),
                  ],
                ),
              ),
              if (hovered && note.status != StashStatus.done)
                Builder(
                  builder: (context) => _IconAction(
                    icon: Codicons.rocket,
                    tooltip: l10n.stashImplement,
                    onTap: () {
                      final box = context.findRenderObject() as RenderBox?;
                      unawaited(
                        implementStash(
                          context,
                          controller,
                          note.id,
                          anchor: box == null
                              ? null
                              : box.localToGlobal(Offset.zero) & box.size,
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return Draggable<StashDragData>(
      data: StashDragData([stashReferenceOf(controller.store, note)]),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(
            '${note.tag} ${note.displayTitle}',
            style: TextStyle(color: AppColors.text, fontSize: 12),
          ),
        ),
      ),
      child: row,
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IdeHover(
    message: tooltip,
    child: HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: hovered
                ? themeColors['toolbar.hoverBackground']
                : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Icon(icon, size: 13, color: AppColors.textMuted),
        ),
      ),
    ),
  );
}
