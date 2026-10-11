import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_explorer.dart';

import 'fake_files.dart';

/// The explorer as VS Code's: a click below the rows selects none, what is
/// dragged onto a folder moves into it, and file operations are undone and
/// done again.
void main() {
  Future<(IdeExplorerController, TreeFiles)> pumpTree(
    WidgetTester tester,
  ) async {
    final files = TreeFiles({
      inRoot('lib/a.dart'): 'a',
      inRoot('README.md'): 'r',
    });
    final controller = IdeExplorerController(
      files: files,
      root: testRoot,
      watch: (_) => const Stream.empty(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: IdeExplorer(controller: controller, onOpen: (_, _) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, files);
  }

  /// Drags the row [from] onto the row [onto], in steps.
  Future<void> dragOnto(WidgetTester tester, String from, String onto) async {
    final start = tester.getCenter(find.text(from));
    final end = tester.getCenter(find.text(onto));
    final gesture = await tester.startGesture(start);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(start, end, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  IdeExplorerState explorer(WidgetTester tester) =>
      tester.state<IdeExplorerState>(find.byType(IdeExplorer));

  testWidgets('a click below the rows selects none', (tester) async {
    final (controller, _) = await pumpTree(tester);
    await tester.tap(find.text('README.md'));
    await tester.pump();
    expect(controller.selected, inRoot('README.md'));

    await tester.tapAt(
      tester.getBottomLeft(find.byType(IdeExplorer)) + const Offset(40, -20),
    );
    await tester.pump();
    expect(controller.selected, isNull);
    expect(controller.selection, isEmpty);
  });

  testWidgets('a file dragged onto a folder moves into it; undone and done '
      'again', (tester) async {
    final (controller, files) = await pumpTree(tester);
    await dragOnto(tester, 'README.md', 'lib');
    expect(files.contents.keys, contains(inRoot('lib/README.md')));
    expect(files.contents.keys, isNot(contains(inRoot('README.md'))));
    expect(explorer(tester).canUndo, isTrue);

    await explorer(tester).undo();
    await tester.pumpAndSettle();
    expect(files.contents.keys, contains(inRoot('README.md')));
    expect(files.contents.keys, isNot(contains(inRoot('lib/README.md'))));
    expect(explorer(tester).canRedo, isTrue);

    await explorer(tester).redo();
    await tester.pumpAndSettle();
    expect(files.contents.keys, contains(inRoot('lib/README.md')));
    expect(controller.selected, inRoot('lib/README.md'));
  });

  testWidgets('a folder is not dropped into itself', (tester) async {
    final (_, files) = await pumpTree(tester);
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    await tester.timedDrag(
      find.text('lib'),
      tester.getCenter(find.text('a.dart')) - tester.getCenter(find.text('lib')),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(files.contents.keys, contains(inRoot('lib/a.dart')));
    expect(explorer(tester).canUndo, isFalse);
  });

  testWidgets('a file made is deleted by Undo, made again by Redo', (
    tester,
  ) async {
    final (_, files) = await pumpTree(tester);
    await explorer(tester).startCreate(directory: false);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'notes/new.txt');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(files.contents[inRoot('notes/new.txt')], '');
    expect(files.folders, contains(inRoot('notes')));

    await explorer(tester).undo();
    await tester.pumpAndSettle();
    expect(files.contents.keys, isNot(contains(inRoot('notes/new.txt'))));
    expect(files.folders, isNot(contains(inRoot('notes'))));

    await explorer(tester).redo();
    await tester.pumpAndSettle();
    expect(files.contents[inRoot('notes/new.txt')], '');

    // Changed since: Undo asks before deleting it.
    files.contents[inRoot('notes/new.txt')] = 'kept';
    final undo = explorer(tester).undo();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await undo;
    expect(files.contents[inRoot('notes/new.txt')], 'kept');
  });

  testWidgets('a file deleted for good is made again by Undo', (tester) async {
    final (_, files) = await pumpTree(tester);
    await tester.tap(find.text('README.md'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(files.contents.keys, isNot(contains(inRoot('README.md'))));

    await explorer(tester).undo();
    await tester.pumpAndSettle();
    expect(utf8.decode(files.bytes[inRoot('README.md')]!), 'r');
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('Cmd+Z in the tree undoes', (tester) async {
    final (_, files) = await pumpTree(tester);
    await tester.tap(find.text('README.md'));
    await tester.pump();
    final state = explorer(tester);
    await dragOnto(tester, 'README.md', 'lib');
    expect(state.canUndo, isTrue);

    await tester.tap(find.text('lib'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(files.contents.keys, contains(inRoot('README.md')));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
