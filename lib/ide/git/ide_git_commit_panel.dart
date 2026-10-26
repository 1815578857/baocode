// The local changes as JetBrains IDEs' Commit tool window has them: a tree
// of the changes whose files are checked to be committed (the tracked ones
// at first, the unversioned ones not), as Changes, Unversioned Files and
// Merge Conflicts (under each repository's name where there are several);
// a toolbar over it (Refresh, Rollback, Show Diff, Group by Directory,
// Expand All, Collapse All); under it, Amend, the commit message, and
// Commit and Commit and Push. No staging: the files checked are committed
// as they are in the working tree (`git commit --only -- <paths>`).
//
// A file clicked shows its changes (in the Git log's table's place); a
// double click, Enter or Jump to Source opens it in the editor. Space
// checks and unchecks the row focused; Left and Right fold and unfold.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../base/smooth_scroll.dart';
import '../../chat/composer/composer_files.dart';
import '../../chat/composer/file_drag.dart';
import '../../l10n/l10n.dart';
import '../../theme/codicons.dart';
import '../../theme/material_file_icons.dart';
import '../../theme/workbench_theme.dart';
import '../ide_button.dart';
import '../ide_dialog.dart';
import '../ide_hover.dart';
import '../ide_spinning.dart';
import '../ide_input.dart';
import '../ide_list.dart';
import '../ide_menu.dart';
import '../ide_notifications.dart';
import 'commit_message.dart';
import 'git_model.dart';
import 'git_repository.dart';
import 'git_service.dart';
import 'ide_git_merge_dialog.dart';
import 'ide_scm_view.dart' show IdeScmSession;
import 'scm_host.dart';
import 'scm_tree.dart';

class IdeGitCommitPanel extends StatefulWidget {
  const IdeGitCommitPanel({
    super.key,
    required this.host,
    required this.session,
    this.sessionOf,
    required this.notifications,
    required this.onOpen,
    required this.onOpenChange,
    this.onRevealInExplorer,
    this.revealInExplorerLabel,
    this.onAddToChat,
    this.trash,
    this.commitMessage,
    this.onTreeViewChanged,
  });

  /// The IDE's workspace, or the chat window's side panel's project.
  final IdeScmHost host;

  /// The session of the repository shown: the commit message, Amend, and
  /// how the tree shows.
  final IdeScmSession session;

  /// Another repository's session, for its check marks and folds; [session]
  /// for all when null.
  final IdeScmSession Function(IdeGitRepository git)? sessionOf;
  final IdeNotifications notifications;

  /// Opens a file in the editor (Jump to Source).
  final Future<void> Function(String path, {bool focusEditor}) onOpen;

  /// Shows a change: its diff, where the host shows one ([focusEditor]: in
  /// the editor, to edit).
  final Future<void> Function(
    IdeGitResource resource, {
    bool head,
    bool focusEditor,
  })
  onOpenChange;

  /// Reveals a file in the explorer; not offered when null.
  final ValueChanged<String>? onRevealInExplorer;
  final String? revealInExplorerLabel;

  /// Puts files in the chat's composer; not offered when null.
  final ValueChanged<List<ComposerFile>>? onAddToChat;

  /// Moves a file to the Trash (true once it did); untracked files rolled
  /// back are deleted where it is null.
  final Future<bool> Function(String path)? trash;

  /// Writes commit messages (the sparkle); none offered when null.
  final IdeCommitMessageModel? commitMessage;

  /// Told when Group by Directory is turned on or off, to remember it.
  final ValueChanged<bool>? onTreeViewChanged;

  static const rowHeight = 22.0;

  @override
  State<IdeGitCommitPanel> createState() => IdeGitCommitPanelState();
}

/// Where a change is listed.
enum _Kind { conflicts, changes, unversioned }

/// A row of the tree: a repository's (where there are several), a group's,
/// a folder's or a file's.
sealed class _Row {
  _Row(this.git, this.depth);

  final IdeGitRepository git;
  final int depth;

  String get key;

  /// The files under it (its own, for a file's).
  List<IdeGitResource> get files;

  /// Its parent's key; null at the top.
  String? parent;
}

final class _RepoRow extends _Row {
  _RepoRow(IdeGitRepository git, this.files) : super(git, 0);

  @override
  final List<IdeGitResource> files;

  @override
  String get key => 'r:${git.service.root}';
}

final class _GroupRow extends _Row {
  _GroupRow(super.git, this.kind, this.files, super.depth);

  final _Kind kind;

  @override
  final List<IdeGitResource> files;

  @override
  String get key => 'g:${git.service.root}:${kind.name}';
}

final class _FolderRow extends _Row {
  _FolderRow(super.git, this.kind, this.folder, this.files, super.depth);

  final _Kind kind;
  final IdeScmTreeFolder folder;

  @override
  final List<IdeGitResource> files;

  @override
  String get key => 'f:${git.service.root}:${kind.name}:${folder.path}';
}

final class _FileRow extends _Row {
  _FileRow(super.git, this.kind, this.resource, super.depth);

  final _Kind kind;
  final IdeGitResource resource;

  @override
  List<IdeGitResource> get files => [resource];

  @override
  String get key => 'x:${git.service.root}:${kind.name}:${resource.path}';
}

class IdeGitCommitPanelState extends State<IdeGitCommitPanel>
    with IdeKeyboardList<IdeGitCommitPanel> {
  final FocusNode _listFocus = FocusNode(debugLabel: 'commit changes');
  final FocusNode _inputFocus = FocusNode(debugLabel: 'commit message');
  final ScrollController _scroll = SmoothScrollController();

  /// The row focused, by key: kept in the session, where it was when the
  /// panel comes back.
  String? get _selected => _session.listSelected;
  set _selected(String? key) => _session.listSelected = key;
  IdeInputValidation? _validation;
  bool _committing = false;

  /// The tree's height above the message, as dragged; null for its
  /// default.
  double? _treeHeight;

  IdeScmSession get _session => widget.session;
  IdeGitRepository? get _git => widget.host.git;

  IdeScmSession _sessionOf(IdeGitRepository git) =>
      identical(git, _git) ? _session : widget.sessionOf?.call(git) ?? _session;

  /// The repositories listed: each of the host's, else its one.
  List<IdeGitRepository> get _repositories {
    final repositories = widget.host.repositories;
    if (repositories.isEmpty) return [?_git];
    return [for (final (_, git) in repositories) git];
  }

  @override
  void initState() {
    super.initState();
    _messageText = _session.message.text;
    _session.message.addListener(_messageChanged);
    _listFocus.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(IdeGitCommitPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.message.removeListener(_messageChanged);
      widget.session.message.addListener(_messageChanged);
      _messageText = widget.session.message.text;
      _validation = null;
    }
  }

  @override
  void dispose() {
    _session.message.removeListener(_messageChanged);
    _listFocus.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// The message's text last seen: the caret moving alone (as when the
  /// input takes the focus) leaves the validation shown.
  String? _messageText;

  void _messageChanged() {
    final text = _session.message.text;
    if (text == _messageText) return;
    _messageText = text;
    if (_validation != null) setState(() => _validation = null);
  }

  // --- What the workbench asks of it ---------------------------------------

  /// Whether the commit message has the keyboard (`scmRepository`).
  bool get inputHasFocus => _inputFocus.hasFocus;

  bool get hasValidation => _validation != null;

  bool get inputHasSelection {
    final selection = _session.message.selection;
    return selection.isValid && !selection.isCollapsed;
  }

  void clearValidation() => setState(() => _validation = null);

  void clearInput() => _session.message.clear();

  /// The tree, where a row was focused; else the commit message.
  void focus() => (_selected == null ? _inputFocus : _listFocus).requestFocus();

  Future<void> commit() => _commit();

  Future<void> fetch() async => _run(() async => _git?.fetch());

  Future<void> fetchAll() => _run(() async {
    for (final git in _repositories) {
      await git.fetch();
    }
  });

  Future<void> pull() => _run(() async => _git?.pull());

  Future<void> push() => _run(() async {
    if (_git case final git?) await ideGitPushOrPublish(git);
  });

  /// [resource]'s conflict in the merge dialog.
  Future<void> _mergeConflict(IdeGitRepository git, IdeGitResource resource) =>
      showIdeGitMergeDialog(
        context,
        git: git,
        resource: resource,
        host: widget.host,
        notifications: widget.notifications,
        ai: widget.commitMessage,
      );

  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error) {
      if (mounted) widget.notifications.notify(IdeSeverity.error, '$error');
    }
  }

  // --- The changes ---------------------------------------------------------

  /// [state]'s changes by where they are listed: the conflicts, the tracked
  /// changes (once each, staged or not), the unversioned files.
  static Map<_Kind, List<IdeGitResource>> _changesOf(IdeGitState state) {
    final tracked = <String, IdeGitResource>{};
    final unversioned = <IdeGitResource>[];
    for (final resource in state.group(IdeGitGroup.staged)) {
      tracked[resource.path] = resource;
    }
    for (final resource in state.group(IdeGitGroup.workingTree)) {
      if (resource.status == IdeGitStatus.untracked) {
        unversioned.add(resource);
        continue;
      }
      // A file staged then changed again: as it is now, unless what was
      // staged says more (added, renamed, deleted).
      final staged = tracked[resource.path];
      if (staged == null || staged.status == IdeGitStatus.indexModified) {
        tracked[resource.path] = resource;
      }
    }
    int byPath(IdeGitResource a, IdeGitResource b) => a.path.compareTo(b.path);
    return {
      _Kind.conflicts: [...state.group(IdeGitGroup.merge)]..sort(byPath),
      _Kind.changes: tracked.values.toList()..sort(byPath),
      _Kind.unversioned: unversioned..sort(byPath),
    };
  }

  bool _isChecked(IdeGitRepository git, IdeGitResource resource) =>
      _sessionOf(git).included[resource.path] ??
      resource.status != IdeGitStatus.untracked;

  /// Whether [files] are checked: all (true), none (false), or some (null).
  bool? _checkedOf(IdeGitRepository git, List<IdeGitResource> files) {
    var all = true;
    var none = true;
    for (final file in files) {
      if (_isChecked(git, file)) {
        none = false;
      } else {
        all = false;
      }
    }
    return all ? true : (none ? false : null);
  }

  void _setChecked(
    IdeGitRepository git,
    Iterable<IdeGitResource> files,
    bool value,
  ) {
    final included = _sessionOf(git).included;
    setState(() {
      for (final file in files) {
        included[file.path] = value;
      }
      _validation = null;
    });
  }

  /// The files to commit in [git]: the checked ones still changed.
  List<IdeGitResource> _toCommit(IdeGitRepository git) {
    final state = git.state;
    if (state == null) return const [];
    final changes = _changesOf(state);
    return [
      for (final kind in const [_Kind.changes, _Kind.unversioned])
        for (final file in changes[kind]!)
          if (_isChecked(git, file)) file,
    ];
  }

  // --- The tree's rows -----------------------------------------------------

  bool _collapsed(IdeGitRepository git, String key) =>
      _sessionOf(git).collapsedFolders.contains(key);

  void _setCollapsed(_Row row, bool collapsed) {
    final folds = _sessionOf(row.git).collapsedFolders;
    setState(() {
      if (collapsed) {
        folds.add(row.key);
      } else {
        folds.remove(row.key);
      }
    });
  }

  List<_Row> get _rows {
    final repositories = [
      for (final git in _repositories)
        if (git.state != null) git,
    ];
    final several = repositories.length > 1;
    final rows = <_Row>[];
    for (final git in repositories) {
      final state = git.state!;
      final changes = _changesOf(state);
      final all = [for (final files in changes.values) ...files];
      if (all.isEmpty && several) continue;
      var depth = 0;
      String? parent;
      if (several) {
        final row = _RepoRow(git, all);
        rows.add(row);
        if (_collapsed(git, row.key)) continue;
        depth = 1;
        parent = row.key;
      }
      final byDirectory = _sessionOf(git).treeView;
      for (final kind in _Kind.values) {
        final files = changes[kind]!;
        if (files.isEmpty) continue;
        final group = _GroupRow(git, kind, files, depth)..parent = parent;
        rows.add(group);
        if (_collapsed(git, group.key)) continue;
        if (!byDirectory) {
          for (final file in files) {
            rows.add(_FileRow(git, kind, file, depth + 1)..parent = group.key);
          }
          continue;
        }
        void add(List<IdeScmTreeNode> nodes, int depth, String parent) {
          for (final node in nodes) {
            switch (node) {
              case IdeScmTreeFolder():
                final folder = _FolderRow(
                  git,
                  kind,
                  node,
                  _filesUnder(node),
                  depth,
                )..parent = parent;
                rows.add(folder);
                if (!_collapsed(git, folder.key)) {
                  add(node.children, depth + 1, folder.key);
                }
              case IdeScmTreeFile(:final resource):
                rows.add(_FileRow(git, kind, resource, depth)..parent = parent);
            }
          }
        }

        add(
          ideScmTree(state.root, files, paths: git.service.pathContext),
          depth + 1,
          group.key,
        );
      }
    }
    return rows;
  }

  static List<IdeGitResource> _filesUnder(IdeScmTreeFolder folder) => [
    for (final node in folder.children)
      ...switch (node) {
        IdeScmTreeFolder() => _filesUnder(node),
        IdeScmTreeFile(:final resource) => [resource],
      },
  ];

  bool _hasChildren(_Row row) => row is! _FileRow;

  // --- Acting --------------------------------------------------------------

  void _select(_Row row, {bool reveal = false}) {
    setState(() => _selected = row.key);
    if (!reveal) return;
    final index = _rows.indexWhere((candidate) => candidate.key == row.key);
    if (index >= 0) {
      ideRevealRow(_scroll, index, rowHeight: IdeGitCommitPanel.rowHeight);
    }
  }

  /// A file's changes: where the host shows them, or ([editor]) in the
  /// editor.
  Future<void> _show(_FileRow row, {bool editor = false}) async {
    if (!identical(row.git, _git)) widget.host.selectRepository(row.git);
    await widget.onOpenChange(row.resource, focusEditor: editor);
  }

  void _toggleCheck(_Row row) {
    if (row is _GroupRow && row.kind == _Kind.conflicts) return;
    if (row is _FileRow && row.kind == _Kind.conflicts) return;
    final files = _checkable(row);
    if (files.isEmpty) return;
    _setChecked(row.git, files, _checkedOf(row.git, files) != true);
  }

  /// The files under [row] that a check mark is for: not the conflicts.
  List<IdeGitResource> _checkable(_Row row) => [
    for (final file in row.files)
      if (file.group != IdeGitGroup.merge) file,
  ];

  // --- The workbench's list.* commands (IdeKeyboardList) -----------------

  int get _focusedIndex => _rows.indexWhere((row) => row.key == _selected);

  _Row? get _focusedRow {
    final rows = _rows;
    final at = rows.indexWhere((row) => row.key == _selected);
    return at < 0 ? null : rows[at];
  }

  @override
  bool get listHasFocus => _listFocus.hasFocus;

  @override
  int get listLength => _rows.length;

  @override
  int get listFocusedIndex => _focusedIndex;

  @override
  void listFocusAt(int index) {
    final rows = _rows;
    if (rows.isEmpty) return;
    _select(rows[index.clamp(0, rows.length - 1)], reveal: true);
  }

  @override
  int get listPageSize =>
      ideRowsPerPage(_scroll, rowHeight: IdeGitCommitPanel.rowHeight);

  /// Enter: a file's changes in the editor; a group or folder folds.
  @override
  void listSelect() {
    final row = _focusedRow;
    if (row == null) return;
    if (row is _FileRow) {
      unawaited(_show(row, editor: true));
    } else {
      _setCollapsed(row, !_collapsed(row.git, row.key));
    }
  }

  /// Space: as in JetBrains IDEs, checks or unchecks the row.
  @override
  void listToggleExpand() {
    if (_focusedRow case final row?) _toggleCheck(row);
  }

  @override
  void listExpand() {
    final rows = _rows;
    final at = _focusedIndex;
    if (at < 0) return;
    final row = rows[at];
    if (!_hasChildren(row)) return;
    if (_collapsed(row.git, row.key)) {
      _setCollapsed(row, false);
    } else if (at + 1 < rows.length) {
      listFocusAt(at + 1);
    }
  }

  @override
  void listCollapse() {
    final row = _focusedRow;
    if (row == null) return;
    if (_hasChildren(row) && !_collapsed(row.git, row.key)) {
      _setCollapsed(row, true);
    } else if (row.parent case final parent?) {
      final index = _rows.indexWhere((row) => row.key == parent);
      if (index >= 0) listFocusAt(index);
    }
  }

  @override
  void listCollapseAll() => _collapseAll();

  @override
  bool listTreeKey(String key) {
    final rows = _rows;
    final at = _focusedIndex;
    if (at < 0) return false;
    final row = rows[at];
    final open = _hasChildren(row) && !_collapsed(row.git, row.key);
    return switch (key) {
      'treeElementCanCollapse' => open,
      'treeElementCanExpand' =>
        _hasChildren(row) && _collapsed(row.git, row.key),
      'treeElementHasChild' =>
        open && at + 1 < rows.length && rows[at + 1].parent == row.key,
      'treeElementHasParent' => row.parent != null,
      _ => false,
    };
  }

  /// Every group and folder folded.
  void _collapseAll() => setState(() {
    for (final row in _rows) {
      if (_hasChildren(row) && row is! _RepoRow) {
        _sessionOf(row.git).collapsedFolders.add(row.key);
      }
    }
  });

  /// The tree's keys where no workbench routes them (the side panel).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_rows.isEmpty) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        listFocusNext(1);
      case LogicalKeyboardKey.arrowUp:
        listFocusNext(-1);
      case LogicalKeyboardKey.pageDown:
        listFocusPage(1);
      case LogicalKeyboardKey.pageUp:
        listFocusPage(-1);
      case LogicalKeyboardKey.home:
        listFocusFirst();
      case LogicalKeyboardKey.end:
        listFocusLast();
      case LogicalKeyboardKey.arrowRight:
        listExpand();
      case LogicalKeyboardKey.arrowLeft:
        listCollapse();
      case LogicalKeyboardKey.space:
        listToggleExpand();
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        listSelect();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Commits the files checked in each repository with the message (Amend:
  /// into the last commit); then, with [push], pushes them.
  Future<void> _commit({bool push = false}) async {
    if (_committing) return;
    final l10n = context.l10n;
    final message = _session.message.text.trim();
    final amend = _session.amend;
    final work = [
      for (final git in _repositories)
        if (_toCommit(git) case final files when files.isNotEmpty) (git, files),
    ];
    if (message.isEmpty && !amend) {
      setState(
        () => _validation = IdeInputValidation(l10n.gitCommitEmptyMessage),
      );
      _inputFocus.requestFocus();
      return;
    }
    if (work.isEmpty && !amend) {
      setState(
        () => _validation = IdeInputValidation(l10n.gitCommitNothingSelected),
      );
      return;
    }
    setState(() => _committing = true);
    try {
      if (work.isEmpty) {
        // Amend alone: the last commit's message.
        await _git?.commitResources(message, const [], amend: true);
      }
      for (final (git, files) in work) {
        await git.commitResources(message, files, amend: amend);
        _sessionOf(git).included.clear();
      }
      _session
        ..message.clear()
        ..amend = false;
      if (push) {
        for (final git in {
          for (final (git, _) in work) git,
          if (work.isEmpty) ?_git,
        }) {
          await ideGitPushOrPublish(git);
        }
      }
    } catch (error) {
      if (mounted) widget.notifications.notify(IdeSeverity.error, '$error');
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  /// Amend checked: the last commit's message in the input, where none is
  /// written yet.
  Future<void> _setAmend(bool value) async {
    setState(() => _session.amend = value);
    final git = _git;
    if (!value || git == null || _session.message.text.trim().isNotEmpty) {
      return;
    }
    final head = await git.headCommit();
    if (!mounted || head == null || !_session.amend) return;
    if (_session.message.text.trim().isNotEmpty) return;
    final text = head.message.trim();
    _session.message.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Rollback… on [files] of [git], asked first.
  Future<void> _rollback(
    IdeGitRepository git,
    List<IdeGitResource> files,
  ) async {
    if (files.isEmpty) return;
    final l10n = context.l10n;
    final choice = await showIdeDialog(
      context,
      message: l10n.gitCommitRollbackConfirm(files.length),
      detail: l10n.gitCommitRollbackDetail,
      buttons: [l10n.gitCommitRollbackButton],
    );
    if (choice != 0) return;
    await _run(() => git.rollback(files, trash: widget.trash));
  }

  /// The files Rollback acts on from the toolbar: the row focused's, else
  /// the checked ones.
  List<(IdeGitRepository, List<IdeGitResource>)> get _rollbackTargets {
    final rows = _rows;
    final focused = rows.where((row) => row.key == _selected).firstOrNull;
    if (focused != null) return [(focused.git, focused.files)];
    return [
      for (final git in _repositories)
        if (_toCommit(git) case final files when files.isNotEmpty) (git, files),
    ];
  }

  /// Generates the commit message from what the commit would take (the
  /// checked files' diff); again while it runs, cancels it.
  Future<void> _generateMessage() async {
    final model = widget.commitMessage;
    final git = _git;
    final state = git?.state;
    if (model == null || git == null || state == null) return;
    final l10n = context.l10n;
    if (_session.generating case final running?) {
      running.complete();
      return;
    }
    final cancel = _session.generating = Completer<void>();
    setState(() {});
    try {
      final files = _toCommit(git);
      // The files checked, as the commit takes them: HEAD against the
      // working tree (with no HEAD yet, what is staged).
      final unborn = state.head.unborn;
      final diff = await git.service.diff(
        staged: unborn,
        paths: unborn
            ? null
            : [
                for (final file in files)
                  if (file.status != IdeGitStatus.untracked) file.path,
              ],
        untracked: [
          for (final file in files)
            if (file.status == IdeGitStatus.untracked) file.path,
        ],
      );
      if (cancel.isCompleted) return;
      if (diff.trim().isEmpty) {
        widget.notifications.notify(
          IdeSeverity.info,
          l10n.scmNoChangesToGenerate,
        );
        return;
      }
      final recent = state.head.unborn
          ? const <IdeGitCommit>[]
          : await git.service.log(limit: 10);
      final message = await model(
        ideCommitMessagePrompt(
          diff,
          recentMessages: [for (final commit in recent) commit.message],
          branch: state.head.branch,
        ),
        cancel: cancel.future,
      );
      if (cancel.isCompleted || message.isEmpty) return;
      _session.message.value = TextEditingValue(
        text: message,
        selection: TextSelection.collapsed(offset: message.length),
      );
    } on IdeCommitMessageCancelled {
      // Cancelled: the message stays as it was.
    } catch (error) {
      if (!cancel.isCompleted) {
        widget.notifications.notify(IdeSeverity.error, '$error');
      }
    } finally {
      if (identical(_session.generating, cancel)) _session.generating = null;
      if (mounted) setState(() {});
    }
  }

  // --- Building ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final repositories = _repositories;
    final git = _git;
    if (git == null) return _Welcome(context.l10n.scmNoProviders);
    return ListenableBuilder(
      listenable: Listenable.merge(repositories),
      builder: (context, _) => !git.loaded
          ? const SizedBox.shrink()
          : git.state == null
          ? _welcome(git)
          : LayoutBuilder(
              builder: (context, constraints) {
                final rows = _rows;
                // The message and its buttons: what is left to the tree, a
                // third at least.
                final treeHeight = math.max(
                  80.0,
                  math.min(
                    _treeHeight ?? constraints.maxHeight * .55,
                    constraints.maxHeight - 170,
                  ),
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _toolbar(context),
                    if (git.state?.operation case final operation?)
                      _operationBanner(git, operation),
                    // Past Git's status limit: what is listed is not all.
                    if (git.state?.didHitLimit ?? false)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
                        child: Text(
                          context.l10n.scmTooManyChanges(
                            IdeGitService.statusLimit,
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            color: themeColors['editorWarning.foreground'],
                          ),
                        ),
                      ),
                    SizedBox(
                      height: treeHeight,
                      child: rows.isEmpty
                          ? _empty(context)
                          : _tree(context, rows),
                    ),
                    _Divider(
                      onDrag: (delta) =>
                          setState(() => _treeHeight = treeHeight + delta),
                    ),
                    Expanded(child: _commitArea(context)),
                  ],
                );
              },
            ),
    );
  }

  /// The merge, rebase, cherry-pick or revert Git stopped in: what, how
  /// many conflicts are left, and Continue (once there are none), Skip
  /// and Abort.
  Widget _operationBanner(IdeGitRepository git, IdeGitOperation operation) {
    final l10n = context.l10n;
    final conflicts = git.state?.group(IdeGitGroup.merge).length ?? 0;
    final branch = git.state?.head.branch;
    final what = switch (operation) {
      IdeGitOperation.rebase => l10n.gitOperationRebasing,
      IdeGitOperation.merge => l10n.gitOperationMerging,
      IdeGitOperation.cherryPick => l10n.gitOperationCherryPicking,
      IdeGitOperation.revert => l10n.gitOperationReverting,
    };
    final warning = themeColors['editorWarning.foreground'];
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: warning.withValues(alpha: .08),
        border: Border.all(color: warning.withValues(alpha: .45)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Codicons.gitMerge, size: 14, color: warning),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  [
                    if (branch != null) '$what · $branch' else what,
                    conflicts > 0
                        ? l10n.gitOperationConflicts(conflicts)
                        : l10n.gitOperationResolved,
                  ].join('  —  '),
                  style: TextStyle(
                    fontSize: 12,
                    color: IdeListColors.foreground,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              IdeButton(
                label: l10n.gitOperationContinue,
                onPressed: conflicts > 0
                    ? null
                    : () => unawaited(_run(git.continueOperation)),
              ),
              if (operation.skips)
                IdeButton(
                  label: l10n.gitOperationSkip,
                  secondary: true,
                  onPressed: () =>
                      unawaited(_run(() => git.continueOperation(skip: true))),
                ),
              IdeButton(
                label: l10n.gitOperationAbort,
                secondary: true,
                onPressed: () => unawaited(_abort(git, what)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Abort, once confirmed: what was done since it began is undone.
  Future<void> _abort(IdeGitRepository git, String what) async {
    final l10n = context.l10n;
    final answer = await showIdeDialog(
      context,
      message: l10n.gitOperationAbortConfirm(what),
      buttons: [l10n.gitOperationAbort],
    );
    if (answer != 0) return;
    await _run(() => git.continueOperation(abort: true));
  }

  /// Not a repository: why, and Initialize Repository where Git is there.
  Widget _welcome(IdeGitRepository git) {
    final l10n = context.l10n;
    if (git.error case final IdeGitException error
        when error.message.startsWith('Git is')) {
      return _Welcome('${l10n.scmInstallGit}\n\n${error.message}');
    }
    return _Welcome(
      l10n.scmNoRepository,
      button: l10n.scmInitializeRepository,
      onPressed: () => unawaited(_run(git.initialize)),
    );
  }

  Widget _empty(BuildContext context) => Center(
    child: Text(
      context.l10n.gitCommitNoChanges,
      style: TextStyle(fontSize: 12, color: IdeListColors.description),
    ),
  );

  Widget _toolbar(BuildContext context) {
    final l10n = context.l10n;
    final git = _git;
    final rows = _rows;
    final focused = rows.where((row) => row.key == _selected).firstOrNull;
    final byDirectory = git == null ? true : _sessionOf(git).treeView;
    return SizedBox(
      height: 30,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            IdeActionButton(
              icon: Codicons.refresh,
              tooltip: l10n.commonRefresh,
              onPressed: () => unawaited(
                _run(() async {
                  for (final git in _repositories) {
                    await git.refresh(force: true);
                  }
                }),
              ),
            ),
            IdeActionButton(
              icon: Codicons.discard,
              tooltip: l10n.gitCommitRollback,
              onPressed: _rollbackTargets.isEmpty
                  ? null
                  : () => unawaited(() async {
                      for (final (git, files) in _rollbackTargets) {
                        await _rollback(git, files);
                      }
                    }()),
            ),
            IdeActionButton(
              icon: Codicons.diff,
              tooltip: l10n.gitCommitShowDiff,
              // A click shows it in the log's place; this, in the editor.
              onPressed: focused is _FileRow
                  ? () => unawaited(_show(focused, editor: true))
                  : null,
            ),
            const SizedBox(width: 4),
            IdeActionButton(
              icon: Codicons.folder,
              tooltip: l10n.gitCommitGroupByDirectory,
              checked: byDirectory,
              onPressed: () {
                setState(() {
                  for (final git in _repositories) {
                    _sessionOf(git).treeView = !byDirectory;
                  }
                });
                widget.onTreeViewChanged?.call(!byDirectory);
              },
            ),
            IdeActionButton(
              icon: Codicons.expandAll,
              tooltip: l10n.gitCommitExpandAll,
              onPressed: () => setState(() {
                for (final git in _repositories) {
                  _sessionOf(git).collapsedFolders.clear();
                }
              }),
            ),
            IdeActionButton(
              icon: Codicons.collapseAll,
              tooltip: l10n.gitCommitCollapseAll,
              onPressed: _collapseAll,
            ),
            const Spacer(),
            if (_repositories.any((git) => git.busy))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: IdeSpinning(
                  Icon(
                    Codicons.loading,
                    size: 14,
                    color: IdeListColors.description,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tree(BuildContext context, List<_Row> rows) => Focus(
    focusNode: _listFocus,
    onKeyEvent: _onKey,
    child: ListView.builder(
      controller: _scroll,
      itemExtent: IdeGitCommitPanel.rowHeight,
      itemCount: rows.length,
      itemBuilder: (context, index) => _row(context, rows[index]),
    ),
  );

  Widget _row(BuildContext context, _Row row) {
    final l10n = context.l10n;
    final git = row.git;
    final selected = row.key == _selected;
    final indent = 4.0 + row.depth * 14.0;
    final collapsed = _hasChildren(row) && _collapsed(git, row.key);
    final conflicts =
        (row is _GroupRow && row.kind == _Kind.conflicts) ||
        (row is _FolderRow && row.kind == _Kind.conflicts) ||
        (row is _FileRow && row.kind == _Kind.conflicts);
    final checkable = _checkable(row);
    final check = conflicts || checkable.isEmpty
        ? const SizedBox(width: 18)
        : _Check(
            value: _checkedOf(git, checkable),
            onTap: () {
              _listFocus.requestFocus();
              _select(row);
              _toggleCheck(row);
            },
          );
    final chevron = SizedBox(
      width: 16,
      child: _hasChildren(row)
          ? Icon(
              collapsed ? Codicons.chevronRight : Codicons.chevronDown,
              size: 14,
              color: IdeListColors.foreground,
            )
          : null,
    );
    final count = TextStyle(fontSize: 12, color: IdeListColors.description);
    final Widget content = switch (row) {
      _RepoRow() => Row(
        children: [
          Icon(Codicons.repo, size: 14, color: IdeListColors.foreground),
          const SizedBox(width: 6),
          Flexible(
            child: IdeResourceLabel(
              name: git.service.pathContext.basename(git.service.root),
              description: git.state?.head.branch,
            ),
          ),
          const SizedBox(width: 8),
          Text(l10n.gitLogFileCount(row.files.length), style: count),
        ],
      ),
      _GroupRow(:final kind) => Row(
        children: [
          Flexible(
            child: Text(
              switch (kind) {
                _Kind.changes => l10n.gitCommitChanges,
                _Kind.unversioned => l10n.gitCommitUnversioned,
                _Kind.conflicts => l10n.gitCommitConflicts,
              },
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: kind == _Kind.conflicts
                    ? themeColors['gitDecoration.conflictingResourceForeground']
                    : IdeListColors.foreground,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(l10n.gitLogFileCount(row.files.length), style: count),
        ],
      ),
      _FolderRow(:final folder) => Row(
        children: [
          FolderIcon(folder.path, expanded: !collapsed),
          const SizedBox(width: 6),
          Flexible(child: IdeResourceLabel(name: folder.label)),
          const SizedBox(width: 8),
          Text('${row.files.length}', style: count),
        ],
      ),
      _FileRow(:final resource) => _fileLabel(git, resource),
    };
    final listRow = IdeListRow(
      key: ValueKey(row.key),
      height: IdeGitCommitPanel.rowHeight,
      selected: selected,
      focused: _listFocus.hasFocus,
      tooltip: switch (row) {
        _FileRow(:final resource) =>
          '${git.service.pathContext.relative(resource.path, from: git.service.root)}'
              ' • ${resource.status.localizedLabel(l10n)}',
        _ => null,
      },
      onTap: () {
        _listFocus.requestFocus();
        _select(row);
        switch (row) {
          case _FileRow():
            unawaited(_show(row));
          // Another repository: the one the log shows; the one shown folds.
          case _RepoRow() when !identical(git, _git):
            widget.host.selectRepository(git);
          case _:
            _setCollapsed(row, !collapsed);
        }
      },
      onDoubleTap: switch (row) {
        // A conflict: its merge, where both sides have the file.
        _FileRow(:final resource)
            when row.kind == _Kind.conflicts && ideGitMergeable(resource) =>
          () => unawaited(_mergeConflict(git, resource)),
        _FileRow() => () => unawaited(_show(row, editor: true)),
        _ => null,
      },
      onContextMenu: (position) {
        _listFocus.requestFocus();
        _select(row);
        unawaited(_menu(context, position, row));
      },
      builder: (context, hovered) => Row(
        children: [
          SizedBox(width: indent),
          chevron,
          check,
          const SizedBox(width: 4),
          Expanded(child: content),
          const SizedBox(width: 8),
        ],
      ),
    );
    // Dragged onto the chat's composer: the file, or the folder, in it.
    final dragged = _composerFiles(row);
    if (dragged.isEmpty) return listRow;
    return FileDraggable(key: listRow.key, files: dragged, child: listRow);
  }

  /// What [row] puts in the chat: a file still there, or a folder itself.
  List<ComposerFile> _composerFiles(_Row row) => switch (row) {
    _FileRow(:final resource)
        when resource.status != IdeGitStatus.deleted &&
            resource.status != IdeGitStatus.indexDeleted =>
      [ComposerFile(resource.path)],
    _FolderRow(:final folder) => [ComposerFile(folder.path, directory: true)],
    _ => const [],
  };

  Widget _fileLabel(IdeGitRepository git, IdeGitResource resource) {
    final paths = git.service.pathContext;
    final byDirectory = _sessionOf(git).treeView;
    final relative = paths.relative(resource.path, from: git.service.root);
    final directory = paths.dirname(relative);
    final status = resource.status;
    return Row(
      children: [
        FileIcon(resource.path),
        const SizedBox(width: 6),
        Expanded(
          child: IdeResourceLabel(
            name: paths.basename(resource.path),
            // JetBrains' colors: the name in its status's.
            nameColor: status.color,
            description: byDirectory || directory == '.' ? null : directory,
            strikeThrough: status.strikeThrough,
          ),
        ),
      ],
    );
  }

  Future<void> _menu(BuildContext context, Offset position, _Row row) {
    final l10n = context.l10n;
    final git = row.git;
    final files = row.files;
    final file = row is _FileRow ? row : null;
    final resource = file?.resource;
    // A file's path, or a folder's.
    final path = switch (row) {
      _FileRow(:final resource) => resource.path,
      _FolderRow(:final folder) => folder.path,
      _RepoRow() => git.service.root,
      _ => null,
    };
    final untracked = [
      for (final file in files)
        if (file.status == IdeGitStatus.untracked) file,
    ];
    final conflicts = [
      for (final file in files)
        if (file.group == IdeGitGroup.merge) file,
    ];
    return showIdeMenu(
      context,
      position: position,
      entries: ideMenuGroups([
        // A repository's remotes, as its header in the log's.
        if (row is _RepoRow) ...[
          [
            IdeMenuAction(
              l10n.scmFetchFromAllRemotes,
              onSelected: () => unawaited(_run(git.fetch)),
            ),
          ],
          [
            IdeMenuAction(
              l10n.scmPull,
              onSelected: () => unawaited(_run(git.pull)),
            ),
            IdeMenuAction(
              l10n.scmPush,
              onSelected: () => unawaited(_run(() => ideGitPushOrPublish(git))),
            ),
          ],
        ],
        [
          if (file != null) ...[
            IdeMenuAction(
              l10n.gitCommitShowDiff,
              onSelected: () => unawaited(_show(file, editor: true)),
            ),
            if (resource!.status != IdeGitStatus.deleted &&
                resource.status != IdeGitStatus.indexDeleted)
              IdeMenuAction(
                l10n.gitCommitJumpToSource,
                onSelected: () =>
                    unawaited(widget.onOpen(resource.path, focusEditor: true)),
              ),
          ],
        ],
        [
          if (_checkable(row).isNotEmpty)
            IdeMenuAction(
              l10n.gitCommitRollback,
              onSelected: () => unawaited(_rollback(git, _checkable(row))),
            ),
          if (untracked.isNotEmpty)
            IdeMenuAction(
              l10n.gitCommitAddToVcs,
              onSelected: () => unawaited(_run(() => git.stage(untracked))),
            ),
          if (conflicts.isNotEmpty) ...[
            if (resource != null && ideGitMergeable(resource))
              IdeMenuAction(
                l10n.gitConflictMerge,
                onSelected: () => unawaited(_mergeConflict(git, resource)),
              ),
            IdeMenuAction(
              l10n.gitConflictAcceptCurrent,
              onSelected: () =>
                  unawaited(_run(() => git.acceptSide(conflicts, ours: true))),
            ),
            IdeMenuAction(
              l10n.gitConflictAcceptIncoming,
              onSelected: () =>
                  unawaited(_run(() => git.acceptSide(conflicts, ours: false))),
            ),
            IdeMenuAction(
              l10n.gitCommitMarkResolved,
              onSelected: () => unawaited(_run(() => git.stage(conflicts))),
            ),
          ],
        ],
        [
          if (path != null) ...[
            IdeMenuAction(
              l10n.gitLogCopyPath,
              onSelected: () =>
                  unawaited(Clipboard.setData(ClipboardData(text: path))),
            ),
            if (row is! _RepoRow)
              IdeMenuAction(
                l10n.gitLogCopyRelativePath,
                onSelected: () => unawaited(
                  Clipboard.setData(
                    ClipboardData(
                      text: git.service.pathContext.relative(
                        path,
                        from: git.service.root,
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.onRevealInExplorer case final reveal?)
              IdeMenuAction(
                widget.revealInExplorerLabel ?? l10n.tabRevealInExplorerView,
                onSelected: () => reveal(path),
              ),
          ],
          if (widget.onAddToChat case final add?)
            // A folder itself; a group, each of its files still there.
            if (row is _FolderRow || row is _FileRow
                    ? _composerFiles(row)
                    : [
                        for (final file in files)
                          if (file.status != IdeGitStatus.deleted &&
                              file.status != IdeGitStatus.indexDeleted)
                            ComposerFile(file.path),
                      ]
                case final chat when chat.isNotEmpty)
              IdeMenuAction(
                l10n.sidePanelAddToChat,
                onSelected: () => add(chat),
              ),
        ],
      ]),
    );
  }

  /// The commit message's lines that fit in [height].
  static int lines(double height) => math.max(1, ((height - 8) / 20).floor());

  /// Under the tree: Amend, the commit message, and the buttons.
  Widget _commitArea(BuildContext context) {
    final l10n = context.l10n;
    final git = _git;
    final total = [
      for (final git in _repositories)
        if (git.state case final state?)
          for (final kind in const [_Kind.changes, _Kind.unversioned])
            ..._changesOf(state)[kind]!,
    ].length;
    final checked = [for (final git in _repositories) ..._toCommit(git)].length;
    final busy = _committing || _repositories.any((git) => git.busy);
    final branch = git?.state?.head.branch;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Check(
                value: _session.amend,
                onTap: () => unawaited(_setAmend(!_session.amend)),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => unawaited(_setAmend(!_session.amend)),
                child: Text(
                  l10n.gitCommitAmend,
                  style: TextStyle(
                    fontSize: 12,
                    color: IdeListColors.foreground,
                  ),
                ),
              ),
              const Spacer(),
              if (branch != null)
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Codicons.gitBranch,
                        size: 13,
                        color: IdeListColors.description,
                      ),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          branch,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: IdeListColors.description,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => IdeInputBox(
                controller: _session.message,
                focusNode: _inputFocus,
                semanticsLabel: l10n.gitCommitMessage,
                placeholder: l10n.gitCommitMessage,
                // As many lines as fit.
                minLines: lines(constraints.maxHeight),
                maxLines: lines(constraints.maxHeight),
                lineHeight: 20,
                validation: _validation,
                floatingValidation: true,
                shortcuts: {
                  const SingleActivator(
                    LogicalKeyboardKey.enter,
                    control: true,
                  ): () =>
                      unawaited(_commit()),
                  const SingleActivator(
                    LogicalKeyboardKey.enter,
                    meta: true,
                  ): () =>
                      unawaited(_commit()),
                },
                toggles: [
                  if (widget.commitMessage != null)
                    IdeActionButton(
                      icon: _session.generating == null
                          ? Codicons.sparkle
                          : Codicons.debugStop,
                      tooltip: _session.generating == null
                          ? l10n.scmGenerateCommitMessage
                          : l10n.scmCancelGenerateCommitMessage,
                      size: 20,
                      onPressed: () => unawaited(_generateMessage()),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IdeButton(
                label: l10n.gitCommitButton,
                onPressed: busy ? null : () => unawaited(_commit()),
              ),
              const SizedBox(width: 6),
              IdeButton(
                label: l10n.gitCommitAndPush,
                secondary: true,
                onPressed: busy ? null : () => unawaited(_commit(push: true)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  total == 0 ? '' : l10n.gitCommitSelected(checked, total),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 12,
                    color: IdeListColors.description,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Push, or where the branch has no upstream yet, Publish to its first
/// remote (`origin` first): as JetBrains' Push sets the upstream.
Future<void> ideGitPushOrPublish(IdeGitRepository git) async {
  final head = git.state?.head;
  if (head == null || head.branch == null) return;
  if (head.upstream != null) return git.push();
  final remotes = await git.service.remotes();
  if (remotes.isEmpty) return git.push();
  await git.publish(remotes.contains('origin') ? 'origin' : remotes.first);
}

/// A check box: checked, unchecked, or some of what it stands for (null).
class _Check extends StatelessWidget {
  const _Check({required this.value, required this.onTap});

  final bool? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final on = value != false;
    final accent =
        colors.get('checkbox.selectBackground') ?? colors['button.background'];
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 18,
          height: 18,
          child: Center(
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: on ? accent : colors.get('checkbox.background'),
                border: Border.all(
                  color: on
                      ? accent
                      : colors.get('checkbox.border') ??
                            IdeListColors.description,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
              alignment: Alignment.center,
              child: switch (value) {
                true => Icon(
                  Codicons.check,
                  size: 12,
                  color: colors['button.foreground'],
                ),
                null => Container(
                  width: 8,
                  height: 2,
                  color: colors['button.foreground'],
                ),
                false => null,
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// What shows instead of the changes: a message, and a button under it.
class _Welcome extends StatelessWidget {
  const _Welcome(this.message, {this.button, this.onPressed});

  final String message;
  final String? button;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          message,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: IdeListColors.foreground,
          ),
        ),
        if (button case final button?) ...[
          const SizedBox(height: 12),
          IdeButton(label: button, expand: true, onPressed: onPressed),
        ],
      ],
    ),
  );
}

/// The line between the tree and the message, dragged to size them.
class _Divider extends StatefulWidget {
  const _Divider({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_Divider> createState() => _DividerState();
}

class _DividerState extends State<_Divider> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeRow,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) => widget.onDrag(details.delta.dy),
      child: SizedBox(
        height: 5,
        child: Center(
          child: Container(
            height: _hover ? 3 : 1,
            color: _hover
                ? themeColors['sash.hoverBorder']
                : themeColors.get('panel.border') ?? IdeListColors.description,
          ),
        ),
      ),
    ),
  );
}
