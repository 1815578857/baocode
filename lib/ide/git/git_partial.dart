// Part of a file's changes committed, as JetBrains IDEs' check box by each
// change of a diff in the Commit tool window does it: the changes left
// unchecked stay in the working tree, the file committed as HEAD has it
// with the others in it.

import 'package:flutter/foundation.dart';

import 'package:bao_editor/monaco/flutter/document_snapshot.dart';
import 'package:bao_editor/monaco/flutter/lines_diff.dart';
import 'package:bao_editor/monaco/vs/editor/common/diff/default_lines_diff_computer/default_lines_diff_computer.dart';
import 'package:bao_editor/monaco/vs/editor/common/diff/range_mapping.dart';

import '../ide_agent_edits.dart' show agentHunkSpans;
import '../ide_code_diff.dart' show IdeDiffChecks;
import 'git_model.dart';

/// Whether part of [resource]'s changes can be committed: a file changed
/// in place, in HEAD and in the working tree alike.
bool ideGitPartialCommittable(IdeGitResource resource) =>
    resource.originalPath == null &&
    switch (resource.status) {
      IdeGitStatus.modified || IdeGitStatus.indexModified => true,
      _ => false,
    };

/// How a file's changes are found, in a diff with check boxes and for its
/// commit alike: whitespace counts.
const ideGitHunkOptions = LinesDiffComputerOptions(maxComputationTimeMs: 5000);

/// Each of [changes]' keys: its lines on both sides, and how many changes
/// before it have the same, so that a change keeps its key as lines are
/// added or taken out above it.
List<String> ideGitHunkKeys(
  DocumentSnapshot original,
  DocumentSnapshot modified,
  List<LineRangeMapping> changes,
) {
  String lines(DocumentSnapshot text, LineRange range) {
    if (range.isEmpty) return '';
    final start = text.lineStarts[range.startLineNumber - 1];
    final last = (range.endLineNumberExclusive - 2).clamp(
      0,
      text.lineCount - 1,
    );
    return text.text.substring(start, text.contentEnds[last]);
  }

  final seen = <String, int>{};
  final keys = <String>[];
  for (final change in changes) {
    final text =
        '${lines(original, change.original)}\u0000'
        '${lines(modified, change.modified)}';
    final count = seen.update(text, (n) => n + 1, ifAbsent: () => 0);
    keys.add('$text\u0000$count');
  }
  return keys;
}

/// [modified]'s changes of [original] but those whose keys are [excluded]
/// put in [original]: what a commit of the changes left checked takes.
Future<String> ideGitPartialText(
  String original,
  String modified,
  Set<String> excluded,
) async {
  final before = DocumentSnapshot(original);
  final after = DocumentSnapshot(modified);
  List<String> lines(DocumentSnapshot text) => [
    for (var i = 0; i < text.lineCount; i++)
      text.text.substring(text.lineStarts[i], text.contentEnds[i]),
  ];
  final originalLines = lines(before);
  final modifiedLines = lines(after);
  final diff = isSmallLinesDiff(originalLines, modifiedLines)
      ? DefaultLinesDiffComputer().computeDiff(
          originalLines,
          modifiedLines,
          ideGitHunkOptions,
        )
      : await computeLinesDiffOnIsolate(
          originalLines,
          modifiedLines,
          ideGitHunkOptions,
        );
  final changes = diff.changes;
  final keys = ideGitHunkKeys(before, after, changes);
  final out = StringBuffer();
  var at = 0;
  for (var i = 0; i < changes.length; i++) {
    final spans = agentHunkSpans(changes[i], before, after);
    out.write(original.substring(at, spans.originalStart));
    out.write(
      excluded.contains(keys[i])
          ? original.substring(spans.originalStart, spans.originalEnd)
          : modified.substring(spans.modifiedStart, spans.modifiedEnd),
    );
    at = spans.originalEnd;
  }
  out.write(original.substring(at));
  return out.toString();
}

/// The changes left unchecked in each file (by path): those a commit
/// leaves out.
class IdeGitHunkSelection extends ChangeNotifier {
  final Map<String, Set<String>> _excluded = {};

  /// The files with changes left out.
  Iterable<String> get paths => _excluded.keys;

  bool isPartial(String path) => _excluded[path]?.isNotEmpty ?? false;

  Set<String> excluded(String path) => _excluded[path] ?? const {};

  bool isIncluded(String path, String key) =>
      !(_excluded[path]?.contains(key) ?? false);

  void setIncluded(String path, String key, bool included) {
    final keys = _excluded.putIfAbsent(path, () => {});
    final changed = included ? keys.remove(key) : keys.add(key);
    if (keys.isEmpty) _excluded.remove(path);
    if (changed) notifyListeners();
  }

  /// The check boxes of [path]'s diff.
  IdeDiffChecks checksOf(String path) => _FileChecks(this, path);

  /// [paths] whole again: all their changes checked.
  void clear(Iterable<String> paths) {
    var changed = false;
    for (final path in paths) {
      changed |= _excluded.remove(path) != null;
    }
    if (changed) notifyListeners();
  }
}

class _FileChecks implements IdeDiffChecks {
  _FileChecks(this.selection, this.path);

  final IdeGitHunkSelection selection;
  final String path;

  @override
  bool isIncluded(String key) => selection.isIncluded(path, key);

  @override
  void setIncluded(String key, bool included) =>
      selection.setIncluded(path, key, included);

  @override
  void addListener(VoidCallback listener) => selection.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      selection.removeListener(listener);
}
