import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/git/repository_scan.dart';
import 'package:baocode/ide/ide_workbench.dart';
import 'package:baocode/ide/ide_workspace.dart';

import '../git/fake_git.dart';
import 'fake_files.dart';

/// Source Control's REPOSITORIES and CHANGES with more than one repository
/// (#68, #76): every repository's changes known, Cmd/Ctrl picking several,
/// and CHANGES grouping the picked ones.
void main() {
  late FakeGit own;
  late FakeGit app;

  setUp(() {
    own = FakeGit(testRoot)..status = '## main\x00 M README.md\x00';
    app = FakeGit(inRoot('app'))
      ..status = '## dev\x00 M main.dart\x00?? new.dart\x00';
  });

  Future<void> pumpScm(WidgetTester tester) async {
    await pumpWorkbench(
      tester,
      const {'README.md': '', 'app/main.dart': '', 'app/new.dart': ''},
      git: own.repository(),
      repositoryDetection: IdeRepositoryDetection(
        find: (_) async => [inRoot('app')],
        open: (_) => app.repository(),
      ),
    );
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyG, control: true, shift: true);
    await tester.pumpAndSettle();
  }

  testWidgets('the activity bar counts every repository\'s changes', (
    tester,
  ) async {
    await pumpScm(tester);
    // README.md + main.dart + new.dart.
    expect(find.text('3'), findsWidgets);
  });

  testWidgets('Cmd click adds a repository to the pick, and CHANGES groups '
      'the picked ones', (tester) async {
    await pumpScm(tester);
    // One shown at first: the folder's own, its changes.
    expect(find.text('README.md'), findsWidgets);
    expect(find.text('new.dart'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('app').first);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    // Both repositories' changes show, each under its own header.
    expect(find.text('README.md'), findsWidgets);
    expect(find.text('new.dart'), findsOneWidget);
    expect(find.text('main.dart'), findsOneWidget);
    // Both repository headers are their roots' names, in bold.
    expect(find.text('app'), findsWidgets);
  });

  testWidgets('a plain click shows one repository alone again', (
    tester,
  ) async {
    await pumpScm(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('app').first);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('new.dart'), findsOneWidget);

    await tester.tap(find.text('app').first);
    await tester.pumpAndSettle();
    expect(find.text('new.dart'), findsOneWidget);
    expect(find.text('README.md'), findsNothing);
  });

  testWidgets('a repository\'s header in CHANGES folds and unfolds it', (
    tester,
  ) async {
    await pumpScm(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('app').first);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('new.dart'), findsOneWidget);

    final header = find.byKey(ValueKey('repo:${inRoot('app')}')).first;
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.text('new.dart'), findsNothing);
    expect(find.text('main.dart'), findsNothing);
    // The other repository's changes stay.
    expect(find.text('README.md'), findsWidgets);

    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.text('new.dart'), findsOneWidget);
  });

  test('#68 the workspace knows each file\'s repository', () async {
    final workspace = IdeWorkspace(
      testRoot,
      files: TreeFiles(const {}),
      git: own.repository(),
      repositoryDetection: IdeRepositoryDetection(
        find: (_) async => [inRoot('app')],
        open: (_) => app.repository(),
      ),
    );
    addTearDown(workspace.dispose);
    await pumpEventQueue();
    final ownGit = workspace.repositories.first.$2;
    final appGit = workspace.repositories.last.$2;
    expect(workspace.gitAt(inRoot('app/main.dart')), same(appGit));
    expect(workspace.gitAt(inRoot('README.md')), same(ownGit));
  });

  IdeWorkbenchState workbench(WidgetTester tester) =>
      tester.state<IdeWorkbenchState>(find.byType(IdeWorkbench));

  TestGesture? mouse;
  tearDown(() => mouse = null);

  Future<void> hover(WidgetTester tester, Finder finder) async {
    if (mouse case final mouse?) {
      await mouse.moveTo(tester.getCenter(finder));
    } else {
      final created = mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(created.removePointer);
      await created.addPointer(location: tester.getCenter(finder));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('#73 the CHANGES ... offers Fetch From All Remotes, Pull and '
      'Push', (tester) async {
    await pumpScm(tester);
    await hover(tester, find.text('Changes').first);
    await tester.tap(find.byTooltip('More Actions...').first);
    await tester.pumpAndSettle();
    for (final item in ['Fetch From All Remotes', 'Pull', 'Push']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
  });

  testWidgets('#73/#39 Git: Fetch From All Remotes fetches every repository', (
    tester,
  ) async {
    await pumpScm(tester);
    final state = workbench(tester);
    expect(state.commandsById['git.fetchAll']?.enabled, isTrue);
    expect(state.runCommand('git.fetchAll'), isTrue);
    await tester.pumpAndSettle();
    expect(own.callsTo('fetch'), isNotEmpty);
    expect(app.callsTo('fetch'), isNotEmpty);
  });

  testWidgets('a repository\'s ... Fetch From All Remotes fetches that '
      'repository alone', (tester) async {
    await pumpScm(tester);
    await tester.tap(
      find.byKey(ValueKey('repo-row:${inRoot('app')}')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch From All Remotes'));
    await tester.pumpAndSettle();
    expect(app.callsTo('fetch'), isNotEmpty);
    expect(own.callsTo('fetch'), isEmpty);
  });

  testWidgets('Git: Pull and Git: Push run on the shown repository', (
    tester,
  ) async {
    own.status = '## main...origin/main [ahead 1]\x00 M README.md\x00';
    await pumpScm(tester);
    final state = workbench(tester);
    expect(state.runCommand('git.pull'), isTrue);
    await tester.pumpAndSettle();
    expect(own.callsTo('pull').single, ['pull', '--tags', 'origin', 'main']);

    expect(state.runCommand('git.push'), isTrue);
    await tester.pumpAndSettle();
    expect(own.callsTo('push').single, ['push', 'origin', 'main:main']);
  });
}
