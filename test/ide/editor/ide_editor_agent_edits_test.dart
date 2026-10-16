import 'dart:async';

import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/ide/file_service.dart';
import 'package:baocode/ide/ide_agent_edits.dart';
import 'package:baocode/ide/ide_editor.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/kernel/agent_kernel.dart' show KernelContext;
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../workbench/fake_files.dart';

class _Files with ReadWriteOnlyFiles implements IdeFileService {
  _Files(this.contents);

  final Map<String, String> contents;

  @override
  Future<List<IdeFile>> list(String directory) async => [];

  @override
  Future<String> read(String path, {bool force = false}) async =>
      contents[path]!;

  @override
  Future<void> write(String path, String text, {String? expectedText}) async =>
      contents[path] = text;
}

class _NoStore implements ReviewStore {
  _NoStore(this.root);

  @override
  final String root;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A review of one file, held against [base], recording what the editor
/// asks of it.
class _Review extends ChangeReview {
  _Review(String root, this.file, this.base) : super(_NoStore(root));

  final String file;
  String base;
  int _version = 0;
  final kept = <String>[];
  final settled = <String>[];

  /// What keeping and settling wait on, as the store does.
  Completer<void>? hold;

  @override
  Future<void> begin() async {}

  @override
  Future<void> observe({bool full = true}) async {}

  @override
  String? baseOf(String path) => path == file ? 'v$_version' : null;

  @override
  Future<String> Function()? original(String path) =>
      path == file ? () async => base : null;

  @override
  Future<void> keepPart(String path, String base) async {
    await hold?.future;
    kept.add(base);
    this.base = base;
    _version++;
    notifyListeners();
  }

  @override
  Future<void> settle(Iterable<String> paths) async {
    await hold?.future;
    settled.addAll(paths);
  }
}

final _root = p.join(p.separator, 'agent-edits-project');
final _file = p.join(_root, 'a.txt');

void main() {
  late _Files files;
  late _Review review;

  Future<void> pump(WidgetTester tester, {required String now}) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    files = _Files({_file: now});
    final workspace = IdeWorkspace(_root, files: files);
    addTearDown(workspace.dispose);
    await workspace.open(_file);
    final chat = ChatSession(
      kernel: MockKernels.claudeCode,
      kernelContext: KernelContext(cwd: _root),
      historyCount: 0,
      openReview: (root, {session}) async => review,
    );
    addTearDown(chat.dispose);
    // As a view showing the conversation does: the review opens.
    chat.attach();
    final edits = IdeAgentEdits()..sessions = [chat];
    addTearDown(edits.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IdeEditor(
            workspace: workspace,
            active: workspace.active!,
            nativeEditorEnabled: true,
            onError: (error) => fail('$error'),
            onLspStatus: (_) {},
            onPositionChanged: (_) {},
            agentEdits: edits,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  String text(WidgetTester tester) => tester
      .widget<EditorSurface>(find.byType(EditorSurface))
      .controller
      .value
      .text;

  testWidgets('shows each change in the file with Undo and Keep', (
    tester,
  ) async {
    review = _Review(_root, _file, '1\n2\n3\n4\n5\n');
    await pump(tester, now: 'one\n2\n3\n4\nfive\n');
    final surface = tester.widget<EditorSurface>(find.byType(EditorSurface));
    // The deleted lines above the changes.
    expect(surface.viewZones, hasLength(2));
    expect(find.text('Keep'), findsNWidgets(2));
    expect(find.text('Undo'), findsNWidgets(2));

    // The first kept: the file is held against it, and shows the other.
    await tester.tap(find.text('Keep').first);
    await settle(tester);
    expect(review.kept, ['one\n2\n3\n4\n5\n']);
    expect(find.text('Keep'), findsOneWidget);

    // The other undone: in the text, saved, and looked at again.
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(text(tester), 'one\n2\n3\n4\n5\n');
    expect(files.contents[_file], 'one\n2\n3\n4\n5\n');
    expect(review.settled, [_file]);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('shows Keep and Undo done before the review has them', (
    tester,
  ) async {
    review = _Review(_root, _file, '1\n2\n3\n4\n5\n');
    await pump(tester, now: 'one\n2\n3\n4\nfive\n');
    final hold = review.hold = Completer<void>();

    await tester.tap(find.text('Keep').first);
    await tester.pump();
    await tester.pump();
    expect(find.text('Keep'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump();
    expect(text(tester), 'one\n2\n3\n4\n5\n');
    expect(find.text('Undo'), findsNothing);
    expect(review.kept, isEmpty);

    hold.complete();
    await settle(tester);
    expect(review.kept, ['one\n2\n3\n4\n5\n']);
    expect(review.settled, [_file]);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('shows nothing in a file with no change pending', (tester) async {
    review = _Review(_root, p.join(_root, 'other.txt'), '');
    await pump(tester, now: 'one\n');
    final surface = tester.widget<EditorSurface>(find.byType(EditorSurface));
    expect(surface.viewZones, isEmpty);
    expect(find.text('Keep'), findsNothing);
  });
}

/// Lets the review open, the texts be read and the diff be computed.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  // The diff, computed again after an edit.
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
  await tester.pump();
}
