part of 'ide_git_log_view.dart';

// The branch tree beside the Git log, as JetBrains IDEs have it: HEAD, the
// local branches, the remote ones and the tags, favorites first. A branch
// pressed selects its tip in the log; pressed twice, the log shows it
// alone; its menu has what JetBrains' branch popup has for it: checkout,
// a branch from it, compare, merge, rebase, pull, update, push, rename,
// delete.

extension _Branches on IdeGitLogViewState {
  /// The tree, [refs] once read.
  Widget _branchPane(IdeGitRepository git) => _BranchPane(
    git: git,
    log: _log,
    border: _border,
    onPressed: (ref) => _showRef(git, ref),
    onDoublePressed: (ref) => git.graphBranch = ref.id,
    menu: (ref, refs) => _branchMenu(git, ref, refs),
  );

  /// [ref]'s tip selected in the log; where the log has not loaded it, the
  /// log of [ref] alone, its tip first.
  void _showRef(IdeGitRepository git, IdeGitRef ref) {
    final commit = ref.commit;
    if (commit == null) return;
    if (_ids(git).contains(commit)) {
      _select(commit, reveal: true);
      return;
    }
    git.graphBranch = ref.id;
    _log.reveal(commit);
  }

  /// [ref]'s actions (JetBrains' branch popup's for it); [refs], all of
  /// them, for its upstream's choice.
  List<IdeMenuEntry> _branchMenu(
    IdeGitRepository git,
    IdeGitRef ref,
    List<IdeGitRef> refs,
  ) {
    final l10n = context.l10n;
    final current = git.state?.head.branch;
    final here = current ?? 'HEAD';
    final local = ref.kind == IdeGitRefKind.branch;
    final remote = ref.kind == IdeGitRefKind.remote;
    final tag = ref.kind == IdeGitRefKind.tag;
    final isCurrent = local && ref.name == current;
    void run(Future<void> Function() operation) => unawaited(_run(operation));
    final upstreams = [
      for (final other in refs)
        if (other.kind == IdeGitRefKind.remote && !other.name.endsWith('/HEAD'))
          other,
    ];
    return ideMenuGroups([
      [
        if (!isCurrent)
          IdeMenuAction(
            l10n.gitBranchCheckout,
            onSelected: () => run(() => _checkoutRef(git, ref, refs)),
          ),
        IdeMenuAction(
          l10n.gitBranchNewFrom(ref.name),
          onSelected: () => unawaited(_newBranchFrom(git, ref)),
        ),
        if (local && !isCurrent && current != null)
          IdeMenuAction(
            l10n.gitBranchCheckoutRebase(here),
            onSelected: () =>
                run(() => git.rebaseOnto(current, branch: ref.name)),
          ),
      ],
      [
        if (!isCurrent)
          IdeMenuAction(
            l10n.gitBranchCompare(here),
            onSelected: () => unawaited(_compareWithHead(git, ref)),
          ),
        IdeMenuAction(
          l10n.gitBranchDiffWorkingTree,
          onSelected: () =>
              unawaited(_compareWithLocal(git, ref.name, ref.name)),
        ),
      ],
      [
        if (!isCurrent && current != null) ...[
          IdeMenuAction(
            l10n.gitBranchRebaseOnto(here, ref.name),
            onSelected: () => run(() => git.rebaseOnto(ref.name)),
          ),
          IdeMenuAction(
            l10n.gitBranchMerge(ref.name, here),
            onSelected: () => run(() => git.merge(ref.name)),
          ),
        ],
        if (remote && current != null) ...[
          IdeMenuAction(
            l10n.gitBranchPullRebase(here),
            onSelected: () => run(() => git.pullInto(ref.name, rebase: true)),
          ),
          IdeMenuAction(
            l10n.gitBranchPullMerge(here),
            onSelected: () => run(() => git.pullInto(ref.name, rebase: false)),
          ),
        ],
      ],
      [
        if (local && ref.upstream != null)
          IdeMenuAction(
            l10n.gitBranchUpdate,
            onSelected: () => run(
              isCurrent
                  ? git.pull
                  : () => git.updateBranch(ref.name, ref.upstream!),
            ),
          ),
        if (local)
          IdeMenuAction(
            ref.upstream == null
                ? l10n.gitBranchPush
                : l10n.gitBranchPushTo(ref.upstream!),
            onSelected: () =>
                run(() => git.pushBranch(ref.name, upstream: ref.upstream)),
          ),
        if (local && upstreams.isNotEmpty)
          IdeMenuAction(
            l10n.gitBranchUpstream,
            submenu: [
              for (final upstream in upstreams.take(30))
                IdeMenuAction(
                  upstream.name,
                  checked: upstream.name == ref.upstream,
                  onSelected: () =>
                      run(() => git.setUpstream(ref.name, upstream.name)),
                ),
              if (ref.upstream != null) ...[
                const IdeMenuSeparator(),
                IdeMenuAction(
                  l10n.gitBranchUnsetUpstream,
                  onSelected: () => run(() => git.setUpstream(ref.name, null)),
                ),
              ],
            ],
          ),
        if (local)
          IdeMenuAction(
            l10n.gitBranchRename,
            onSelected: () => unawaited(_renameBranch(git, ref)),
          ),
      ],
      [
        IdeMenuAction(
          _log.isFavorite(git, ref.id)
              ? l10n.gitBranchUnfavorite
              : l10n.gitBranchFavorite,
          onSelected: () => _log.toggleFavorite(git, ref.id),
        ),
        IdeMenuAction(
          l10n.gitBranchShowOnly,
          checked: git.graphBranch == ref.id,
          onSelected: () => git.graphBranch = ref.id,
        ),
      ],
      [
        if (!isCurrent)
          IdeMenuAction(
            tag ? l10n.gitTagDelete : l10n.gitBranchDelete,
            onSelected: () => unawaited(_deleteRef(git, ref)),
          ),
      ],
    ]);
  }

  /// Checkout: a branch; a remote one as the local branch of its name,
  /// made to track it where there is none; a tag, detached.
  Future<void> _checkoutRef(
    IdeGitRepository git,
    IdeGitRef ref,
    List<IdeGitRef> refs,
  ) async {
    switch (ref.kind) {
      case IdeGitRefKind.branch:
        await git.checkout(ref.name);
      case IdeGitRefKind.remote:
        final name = ref.name.substring(ref.name.indexOf('/') + 1);
        final local = refs.any(
          (other) => other.kind == IdeGitRefKind.branch && other.name == name,
        );
        await (local ? git.checkout(name) : git.checkoutTracking(ref.name));
      case IdeGitRefKind.tag:
        await git.checkout(ref.name, detached: true);
      case IdeGitRefKind.head:
        return;
    }
  }

  /// New Branch from: asks for its name, then makes it there and checks
  /// it out.
  Future<void> _newBranchFrom(IdeGitRepository git, IdeGitRef ref) async {
    final l10n = context.l10n;
    final suggested = ref.kind == IdeGitRefKind.remote
        ? ref.name.substring(ref.name.indexOf('/') + 1)
        : '';
    final result = await showIdeInputDialog(
      context,
      message: l10n.gitBranchNewFrom(ref.name),
      buttons: [l10n.branchBarCreateButton],
      inputs: [
        IdeDialogInput(placeholder: l10n.gitBranchName, value: suggested),
      ],
      type: IdeDialogType.question,
    );
    if (result == null || result.button != 0) return;
    final name = ideSanitizeBranchName(result.values.first);
    if (name.isEmpty) return;
    await _run(() => git.branch(name, ref: ref.name));
  }

  Future<void> _renameBranch(IdeGitRepository git, IdeGitRef ref) async {
    final l10n = context.l10n;
    final result = await showIdeInputDialog(
      context,
      message: l10n.gitBranchRenameTitle(ref.name),
      buttons: [l10n.gitBranchRenameButton],
      inputs: [
        IdeDialogInput(placeholder: l10n.gitBranchName, value: ref.name),
      ],
      type: IdeDialogType.question,
    );
    if (result == null || result.button != 0) return;
    final name = ideSanitizeBranchName(result.values.first);
    if (name.isEmpty || name == ref.name) return;
    final favorite = _log.isFavorite(git, ref.id);
    var done = false;
    await _run(() async {
      await git.renameBranch(ref.name, name);
      done = true;
    });
    // A favorite stays one by its new name.
    if (done && favorite) {
      _log
        ..toggleFavorite(git, ref.id)
        ..toggleFavorite(git, 'refs/heads/$name');
    }
  }

  /// Delete: a branch at once, then Restore offered; one with commits
  /// merged nowhere else, once confirmed; a remote one, once confirmed.
  Future<void> _deleteRef(IdeGitRepository git, IdeGitRef ref) async {
    final l10n = context.l10n;
    final commit = ref.commit;
    switch (ref.kind) {
      case IdeGitRefKind.head:
        return;
      case IdeGitRefKind.remote:
        final answer = await showIdeDialog(
          context,
          message: l10n.gitBranchDeleteRemoteConfirm(ref.name),
          buttons: [l10n.gitBranchDeleteButton],
        );
        if (answer != 0) return;
        final remote = ref.remote ?? ref.name.split('/').first;
        await _run(
          () => git.deleteRemoteBranch(
            remote,
            ref.name.substring(remote.length + 1),
          ),
        );
        return;
      case IdeGitRefKind.tag:
        var deleted = false;
        await _run(() async {
          await git.deleteTag(ref.name);
          deleted = true;
        });
        if (deleted && commit != null) {
          _restorable(
            l10n.gitTagDeleted(ref.name),
            () => git.tag(ref.name, commit),
          );
        }
        return;
      case IdeGitRefKind.branch:
        var deleted = false;
        try {
          await git.deleteBranch(ref.name);
          deleted = true;
        } on IdeGitNotMergedException {
          if (!mounted) return;
          final answer = await showIdeDialog(
            context,
            message: l10n.gitBranchNotMergedConfirm(ref.name),
            buttons: [l10n.gitBranchDeleteButton],
          );
          if (answer != 0) return;
          await _run(() async {
            await git.deleteBranch(ref.name, force: true);
            deleted = true;
          });
        } catch (error) {
          _report(error);
        }
        if (deleted && commit != null) {
          _restorable(
            l10n.gitBranchDeleted(ref.name),
            () => git.createBranchAt(ref.name, commit),
          );
        }
    }
  }

  /// [message], with Restore running [restore].
  void _restorable(String message, Future<void> Function() restore) {
    if (!mounted) return;
    widget.notifications.notify(
      IdeSeverity.info,
      message,
      primary: [
        IdeNotificationAction(
          context.l10n.gitBranchRestore,
          () => unawaited(_run(restore)),
        ),
      ],
    );
  }

  /// Compare with Current: how many commits each has the other has not,
  /// and the files they differ in, HEAD's side against [ref]'s.
  Future<void> _compareWithHead(IdeGitRepository git, IdeGitRef ref) async {
    final here = git.state?.head.branch ?? 'HEAD';
    try {
      final counts = await git.service.compareWithHead(ref.name);
      if (!mounted) return;
      widget.notifications.notify(
        IdeSeverity.info,
        context.l10n.gitBranchCompared(
          ref.name,
          here,
          counts.ahead,
          counts.behind,
        ),
      );
    } catch (error) {
      _report(error);
      return;
    }
    await _compareCommits(git, ('HEAD', here), (ref.name, ref.name));
  }
}

/// The branch tree: a filter over HEAD's branch, the local branches, the
/// remote ones and the tags.
class _BranchPane extends StatefulWidget {
  const _BranchPane({
    required this.git,
    required this.log,
    required this.border,
    required this.onPressed,
    required this.onDoublePressed,
    required this.menu,
  });

  final IdeGitRepository git;
  final IdeGitLogController log;
  final Color border;
  final ValueChanged<IdeGitRef> onPressed;
  final ValueChanged<IdeGitRef> onDoublePressed;
  final List<IdeMenuEntry> Function(IdeGitRef ref, List<IdeGitRef> refs) menu;

  @override
  State<_BranchPane> createState() => _BranchPaneState();
}

class _BranchPaneState extends State<_BranchPane> {
  List<IdeGitRef>? _refs;

  /// The status the refs were read for: read again at each.
  IdeGitState? _readFor;
  IdeGitRepository? _readFrom;
  int _request = 0;

  final ScrollController _scroll = SmoothScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _read() {
    final git = widget.git;
    final state = git.state;
    if (identical(state, _readFor) && identical(git, _readFrom)) return;
    if (!identical(git, _readFrom)) _refs = null;
    _readFor = state;
    _readFrom = git;
    final request = ++_request;
    git.refs().then(
      (refs) {
        if (mounted && request == _request) setState(() => _refs = refs);
      },
      onError: (Object _) {
        if (mounted && request == _request) setState(() => _refs = const []);
      },
    );
  }

  String _groupLabel(IdeGitBranchGroup group) {
    final l10n = context.l10n;
    return switch (group) {
      IdeGitBranchGroup.head => l10n.gitBranchesHead,
      IdeGitBranchGroup.local => l10n.gitLogLocalBranches,
      IdeGitBranchGroup.remote => l10n.gitLogRemoteBranches,
      IdeGitBranchGroup.tags => l10n.gitLogTags,
    };
  }

  @override
  Widget build(BuildContext context) {
    _read();
    final l10n = context.l10n;
    final log = widget.log;
    final git = widget.git;
    final refs = _refs;
    final rows = refs == null
        ? const <IdeGitBranchRow>[]
        : ideGitBranchRows(
            refs,
            current: git.state?.head.branch,
            favorites: log.favoriteBranches.of(git.service.root),
            folded: log.foldedBranches,
            filter: log.branchFilter.text,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: IdeInputBox(
            controller: log.branchFilter,
            placeholder: l10n.gitBranchesFilter,
            onChanged: (_) => log.branchFilterChanged(),
          ),
        ),
        Expanded(
          child: refs == null
              ? const SizedBox.shrink()
              : ListView.builder(
                  controller: _scroll,
                  itemExtent: 22,
                  itemCount: rows.length,
                  itemBuilder: (context, index) => _row(rows[index], refs, git),
                ),
        ),
      ],
    );
  }

  Widget _row(IdeGitBranchRow row, List<IdeGitRef> refs, IdeGitRepository git) {
    final log = widget.log;
    final indent = 4.0 + row.depth * 12;
    final ref = row.ref;
    if (ref == null) {
      final expanded = row.expanded ?? true;
      return IdeListRow(
        height: 22,
        onTap: () => log.toggleBranchFolder(row.key),
        builder: (context, _) => Row(
          children: [
            SizedBox(width: indent),
            Icon(
              expanded ? Codicons.chevronDown : Codicons.chevronRight,
              size: 16,
              color: IdeListColors.foreground,
            ),
            const SizedBox(width: 2),
            if (row.group == null) ...[
              Icon(
                row.depth == 1 && row.key.startsWith('remote/')
                    ? Codicons.cloud
                    : Codicons.folder,
                size: 14,
                color: IdeListColors.description,
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                row.group == null ? row.label : _groupLabel(row.group!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: IdeListColors.foreground,
                  fontWeight: row.group == null ? null : FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final current =
        ref.kind == IdeGitRefKind.branch && ref.name == git.state?.head.branch;
    final favorite = row.favorite;
    final track = [
      if ((ref.ahead ?? 0) > 0) '↑${ref.ahead}',
      if ((ref.behind ?? 0) > 0) '↓${ref.behind}',
    ].join(' ');
    return IdeListRow(
      height: 22,
      selected: log.branchSelected == row.key,
      tooltip: [
        ref.name,
        if (ref.upstream case final upstream?) '→ $upstream',
        if (ref.details case final details?) details.subject,
      ].join('\n'),
      onTap: () {
        log.branchSelected = row.key;
        widget.onPressed(ref);
      },
      onDoubleTap: () => widget.onDoublePressed(ref),
      onContextMenu: (position) {
        log.branchSelected = row.key;
        unawaited(
          showIdeMenu(
            context,
            position: position,
            entries: widget.menu(ref, refs),
          ),
        );
      },
      builder: (context, hovered) => Row(
        children: [
          SizedBox(width: indent + 18),
          Icon(
            ref.kind == IdeGitRefKind.tag ? Codicons.tag : Codicons.gitBranch,
            size: 14,
            color: current
                ? themeColors['gitDecoration.addedResourceForeground']
                : IdeListColors.description,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              row.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: IdeListColors.foreground,
                fontWeight: current ? FontWeight.w600 : null,
              ),
            ),
          ),
          if (track.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              track,
              style: TextStyle(fontSize: 11, color: IdeListColors.description),
            ),
          ],
          if (favorite || hovered)
            IdeActionButton(
              icon: favorite ? Codicons.starFull : Codicons.starEmpty,
              tooltip: favorite
                  ? context.l10n.gitBranchUnfavorite
                  : context.l10n.gitBranchFavorite,
              size: 20,
              iconSize: 14,
              color: favorite
                  ? themeColors.get('charts.yellow') ?? IdeListColors.foreground
                  : null,
              onPressed: () => log.toggleFavorite(git, ref.id),
            )
          else
            const SizedBox(width: 20),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
