import 'dart:async';

import 'package:flutter/material.dart';

import 'package:bao_editor/monaco/flutter/document_snapshot.dart';
import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:bao_editor/monaco/vs/editor/common/diff/range_mapping.dart';

import '../chat/chat_session.dart';
import '../chat/review/change_reviews.dart';
import '../l10n/l10n.dart';
import '../theme/workbench_theme.dart' show themeColors;

/// A file's change pending in an agent's conversation, as the editor shows
/// it in the file (Cursor's inline Keep and Undo): held against [base], the
/// text before the agent changed it with what was kept of it since.
class IdeAgentEdit {
  IdeAgentEdit._(this.session, this._review, this.path, this.base);

  final ChatSession session;
  final ChangeReviews _review;
  final String path;

  /// Which text it is held against, anew as part of it is kept (see
  /// [ChangeReviews.baseOf]); empty for a file the agent created.
  final String base;

  /// The text it is held against.
  Future<String> readBase() =>
      _review.original(path)?.call() ?? Future.value('');

  /// Keeps part of it: [base] is what the rest is held against from now.
  Future<void> keepPart(String base) => _review.keepPart(path, base);

  /// Looks at the file again, part of the change undone and saved.
  Future<void> settle() => _review.settle([path]);

  /// Keeps the whole change to the file.
  void keepFile() => unawaited(_review.keep([path]));

  /// Puts the whole file back as it was before the agent changed it.
  void undoFile() => unawaited(_review.undo([path]));
}

/// The agents' changes pending in the files an IDE shows: those of
/// [sessions]' reviews (the IDE's chat first), for its editor to show in
/// each file and keep or undo part by part.
class IdeAgentEdits extends ChangeNotifier {
  List<ChatSession> _sessions = const [];

  /// The reviews listened to, by session: one opens after its session.
  final Map<ChatSession, ChangeReviews?> _reviews = {};
  bool _disposed = false;

  List<ChatSession> get sessions => _sessions;
  set sessions(List<ChatSession> sessions) {
    if (_sameSessions(sessions)) return;
    for (final session in _sessions) {
      if (!sessions.contains(session)) {
        session.removeListener(_sessionChanged);
        _reviews.remove(session)?.removeListener(_changed);
      }
    }
    for (final session in sessions) {
      if (!_sessions.contains(session)) {
        session.addListener(_sessionChanged);
        _reviews[session] = session.changeReview?..addListener(_changed);
      }
    }
    _sessions = List.unmodifiable(sessions);
    // Set as the IDE builds: its listeners hear of it after.
    scheduleMicrotask(_changed);
  }

  bool _sameSessions(List<ChatSession> sessions) {
    if (sessions.length != _sessions.length) return false;
    for (var i = 0; i < sessions.length; i++) {
      if (!identical(sessions[i], _sessions[i])) return false;
    }
    return true;
  }

  /// A session tells of every token: only a review opening or going
  /// matters here.
  void _sessionChanged() {
    var changed = false;
    for (final session in _sessions) {
      final review = session.changeReview;
      if (identical(review, _reviews[session])) continue;
      _reviews[session]?.removeListener(_changed);
      _reviews[session] = review?..addListener(_changed);
      changed = true;
    }
    if (changed) _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// The change pending in the file at [path]; null when none can be
  /// undone there.
  IdeAgentEdit? of(String path) {
    for (final session in _sessions) {
      final review = _reviews[session];
      if (review == null) continue;
      if (review.baseOf(path) case final base?) {
        return IdeAgentEdit._(session, review, path, base);
      }
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final session in _sessions) {
      session.removeListener(_sessionChanged);
    }
    for (final review in _reviews.values) {
      review?.removeListener(_changed);
    }
    super.dispose();
  }
}

/// Where a change between [original] (what the file is held against) and
/// [modified] (its text) is in each, as offsets: replacing one span by the
/// other takes the change out (Undo) or puts it in what the file is held
/// against (Keep). Whole lines with their line breaks; at the end of the
/// texts, the line break before them instead (upstream's
/// `DetailedLineRangeMapping.toRangeMapping2`).
({int originalStart, int originalEnd, int modifiedStart, int modifiedEnd})
agentHunkSpans(
  LineRangeMapping change,
  DocumentSnapshot original,
  DocumentSnapshot modified,
) {
  final o = change.original;
  final m = change.modified;
  int lineStart(DocumentSnapshot text, int line) =>
      line > text.lineCount ? text.text.length : text.lineStarts[line - 1];
  int contentEnd(DocumentSnapshot text, int line) =>
      text.contentEnds[(line - 1).clamp(0, text.lineCount - 1)];
  if (m.endLineNumberExclusive <= modified.lineCount &&
      o.endLineNumberExclusive <= original.lineCount) {
    return (
      originalStart: lineStart(original, o.startLineNumber),
      originalEnd: lineStart(original, o.endLineNumberExclusive),
      modifiedStart: lineStart(modified, m.startLineNumber),
      modifiedEnd: lineStart(modified, m.endLineNumberExclusive),
    );
  }
  if (o.startLineNumber > 1 && m.startLineNumber > 1) {
    return (
      originalStart: contentEnd(original, o.startLineNumber - 1),
      originalEnd: contentEnd(original, o.endLineNumberExclusive - 1),
      modifiedStart: contentEnd(modified, m.startLineNumber - 1),
      modifiedEnd: contentEnd(modified, m.endLineNumberExclusive - 1),
    );
  }
  return (
    originalStart: lineStart(original, o.startLineNumber),
    originalEnd: lineStart(original, o.endLineNumberExclusive),
    modifiedStart: lineStart(modified, m.startLineNumber),
    modifiedEnd: lineStart(modified, m.endLineNumberExclusive),
  );
}

/// [original] with [change] in it: what the file is held against once that
/// part of the change is kept.
String agentHunkKept(
  LineRangeMapping change,
  DocumentSnapshot original,
  DocumentSnapshot modified,
) {
  final s = agentHunkSpans(change, original, modified);
  return original.text.substring(0, s.originalStart) +
      modified.text.substring(s.modifiedStart, s.modifiedEnd) +
      original.text.substring(s.originalEnd);
}

/// Undo and Keep by each change in the editor's text, at the right of the
/// line after it, kept there as the text scrolls ([repaint]).
class IdeAgentHunkActions extends StatelessWidget {
  const IdeAgentHunkActions({
    super.key,
    required this.changes,
    required this.snapshot,
    required this.view,
    required this.repaint,
    required this.onUndo,
    required this.onKeep,
  });

  final List<LineRangeMapping> changes;

  /// The text the changes are of.
  final DocumentSnapshot snapshot;
  final EditorSurfaceView? Function() view;
  final Listenable repaint;
  final ValueChanged<LineRangeMapping> onUndo;
  final ValueChanged<LineRangeMapping> onKeep;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListenableBuilder(
      listenable: repaint,
      builder: (context, _) {
        final view = this.view();
        final area = view?.textArea;
        if (view == null || area == null) return const SizedBox.shrink();
        final text = snapshot;
        final height = view.lineHeight;
        return Stack(
          children: [
            for (final change in changes)
              if (_topOf(view, text, change) case final top?
                  when top >= area.top && top + height <= area.bottom)
                Positioned(
                  key: ObjectKey(change),
                  top: top,
                  right: constraints.maxWidth - area.right + 14,
                  height: height,
                  child: _HunkButtons(
                    onUndo: () => onUndo(change),
                    onKeep: () => onKeep(change),
                  ),
                ),
          ],
        );
      },
    ),
  );

  /// The top of the line after [change] (the bottom of the last, at the
  /// end of the text).
  static double? _topOf(
    EditorSurfaceView view,
    DocumentSnapshot text,
    LineRangeMapping change,
  ) {
    final after = change.modified.endLineNumberExclusive;
    if (after <= text.lineCount) {
      return view.caretRectAt(text.lineStarts[after - 1])?.top;
    }
    return view.caretRectAt(text.text.length)?.bottom;
  }
}

class _HunkButtons extends StatelessWidget {
  const _HunkButtons({required this.onUndo, required this.onKeep});

  final VoidCallback onUndo;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HunkButton(
          label: l10n.stripUndo,
          background: themeColors['button.secondaryBackground'],
          hover: themeColors['button.secondaryHoverBackground'],
          foreground: themeColors['button.secondaryForeground'],
          onTap: onUndo,
        ),
        const SizedBox(width: 4),
        _HunkButton(
          label: l10n.stripKeep,
          background: themeColors['button.background'],
          hover: themeColors['button.hoverBackground'],
          foreground: themeColors['button.foreground'],
          onTap: onKeep,
        ),
      ],
    );
  }
}

class _HunkButton extends StatefulWidget {
  const _HunkButton({
    required this.label,
    required this.background,
    required this.hover,
    required this.foreground,
    required this.onTap,
  });

  final String label;
  final Color background;
  final Color hover;
  final Color foreground;
  final VoidCallback onTap;

  @override
  State<_HunkButton> createState() => _HunkButtonState();
}

class _HunkButtonState extends State<_HunkButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: _hovered ? widget.hover : widget.background,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 11.5,
              height: 1,
              color: widget.foreground,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Over the editor's tabs while its file has an agent's change pending:
/// Undo all and Keep all of the conversation's changes, and Keep of this
/// file's.
class IdeAgentEditActions extends StatelessWidget {
  const IdeAgentEditActions({super.key, required this.edit});

  final IdeAgentEdit edit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final session = edit.session;
    final undoAll = session.undoAllChanges;
    Widget action(String label, VoidCallback? onTap, {bool primary = false}) =>
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: _TitleAction(label: label, onTap: onTap, primary: primary),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          action(l10n.stripUndoAll, undoAll),
          action(l10n.stripKeepAll, session.keepAllChanges),
          action(l10n.agentKeepFile, edit.keepFile, primary: true),
        ],
      ),
    );
  }
}

class _TitleAction extends StatefulWidget {
  const _TitleAction({
    required this.label,
    required this.onTap,
    required this.primary,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  State<_TitleAction> createState() => _TitleActionState();
}

class _TitleActionState extends State<_TitleAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    final primary = widget.primary;
    final background = primary
        ? themeColors[_hovered ? 'button.hoverBackground' : 'button.background']
        : _hovered && onTap != null
        ? themeColors['toolbar.hoverBackground']
        : null;
    final foreground = primary
        ? themeColors['button.foreground']
        : themeColors[onTap == null ? 'disabledForeground' : 'foreground'];
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: widget.label,
      child: MouseRegion(
        cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              widget.label,
              style: TextStyle(fontSize: 12, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}
