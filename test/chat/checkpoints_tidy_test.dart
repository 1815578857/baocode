@TestOn('vm')
library;

import 'dart:io';

import 'package:baocode/chat/review/review_store_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final hasGit = () {
    try {
      return Process.runSync('git', ['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();

  late Directory temp;
  late String root;
  late String checkpoints;
  final long = DateTime.now().subtract(const Duration(days: 60));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('baocode_tidy_');
    final resolved = await temp.resolveSymbolicLinks();
    root = p.join(resolved, 'project');
    checkpoints = p.join(resolved, 'checkpoints');
    await Directory(root).create();
    await File(p.join(root, 'a.txt')).writeAsString('a\n');
  });

  tearDown(() => temp.delete(recursive: true));

  Future<String> git(String gitDir, List<String> arguments) async {
    final result = await Process.run(
      'git',
      ['--git-dir=$gitDir', ...arguments],
      environment: {
        'GIT_AUTHOR_NAME': 'test',
        'GIT_AUTHOR_EMAIL': 'test@localhost',
        'GIT_COMMITTER_NAME': 'test',
        'GIT_COMMITTER_EMAIL': 'test@localhost',
        'GIT_COMMITTER_DATE': '${long.millisecondsSinceEpoch ~/ 1000} +0000',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return '${result.stdout}'.trim();
  }

  /// Session [name]'s snapshots, saved [long] ago.
  Future<void> saveLongAgo(String gitDir, String name) async {
    final tree = await git(gitDir, ['mktree']);
    final commit = await git(gitDir, ['commit-tree', '-m', 'old', tree]);
    await git(gitDir, ['update-ref', 'refs/baocode/sessions/$name', commit]);
  }

  Future<List<String>> sessions(String gitDir) async => (await git(gitDir, [
    'for-each-ref',
    '--format=%(refname:lstrip=3)',
    'refs/baocode/sessions/',
  ])).split('\n').where((line) => line.isNotEmpty).toList();

  test('drops the sessions not saved for a month, keeps the others, and runs '
      'once a day', () async {
    final store = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
    final tree = await store.snapshot();
    await store.save('recent', 'data', trees: [tree], blobs: const []);
    await saveLongAgo(store.gitDir, 'old');
    expect(await sessions(store.gitDir), ['old', 'recent']);

    await GitReviewStore.tidy(checkpoints);
    expect(await sessions(store.gitDir), ['recent']);
    expect(await store.load('recent'), 'data');
    expect(await store.load('old'), isNull);

    // Not again the same day.
    await saveLongAgo(store.gitDir, 'older');
    await GitReviewStore.tidy(checkpoints);
    expect(await sessions(store.gitDir), ['older', 'recent']);
    await GitReviewStore.tidy(
      checkpoints,
      now: DateTime.now().add(const Duration(days: 1, minutes: 1)),
    );
    expect(await sessions(store.gitDir), ['recent']);
  }, skip: !hasGit);

  test("deletes a repository with no session left that nothing used for a "
      "month, but not one open, nor one an agent snapshots in", () async {
    final open = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
    await open.snapshot();
    await saveLongAgo(open.gitDir, 'old');
    await File(p.join(open.gitDir, 'index')).setLastModified(long);

    Future<String> repository(String name) async {
      final gitDir = p.join(checkpoints, name);
      await git(gitDir, ['init', '-q', '--bare', '--template=', gitDir]);
      await saveLongAgo(gitDir, 'old');
      return gitDir;
    }

    final unused = await repository('gone-0000000000000000');
    await File(p.join(unused, 'index')).writeAsString('');
    await File(p.join(unused, 'index')).setLastModified(long);
    // Snapshots taken, not saved yet.
    final working = await repository('working-0000000000000000');
    await File(p.join(working, 'index')).writeAsString('');

    await GitReviewStore.tidy(checkpoints);
    expect(Directory(unused).existsSync(), isFalse);
    expect(Directory(working).existsSync(), isTrue);
    expect(await sessions(working), isEmpty);
    expect(Directory(open.gitDir).existsSync(), isTrue);
    expect(await sessions(open.gitDir), isEmpty);
    // Still at work.
    await File(p.join(root, 'a.txt')).writeAsString('b\n');
    expect(await open.snapshot(), isNotEmpty);
  }, skip: !hasGit);

  test('a missing folder is left be', () async {
    await GitReviewStore.tidy(p.join(temp.path, 'none'));
    expect(Directory(p.join(temp.path, 'none')).existsSync(), isFalse);
  });
}
