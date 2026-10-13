import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:bao_editor/monaco/flutter/editor_surface_controller.dart';
import 'package:baocode/ide/builtin_formatting.dart';
import 'package:baocode/ide/ide_code_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  EditorSurfaceController controllerOf(String text) {
    final controller = EditorSurfaceController(
      document: EditorDocumentModel(text),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('JSON laid out with the indentation, comments kept, one undo', () {
    final controller = controllerOf('{"a":1, // one\n"b":[true,null]}')
      ..tabSize = 2;
    expect(BuiltinFormatting.format(controller, 'jsonc'), isTrue);
    expect(
      controller.document.snapshot.text,
      '{\n  "a": 1, // one\n  "b": [\n    true,\n    null\n  ]\n}',
    );
    controller.document.undo();
    expect(
      controller.document.snapshot.text,
      '{"a":1, // one\n"b":[true,null]}',
    );
    // Laid out already: nothing to do.
    controller.document.redo();
    expect(BuiltinFormatting.format(controller, 'json'), isFalse);
  });

  test('only the languages it knows', () {
    final controller = controllerOf('{"a":1}');
    expect(BuiltinFormatting.supports('typescript'), isFalse);
    expect(BuiltinFormatting.format(controller, 'typescript'), isFalse);
    expect(BuiltinFormatting.format(controller, null), isFalse);
    expect(controller.document.snapshot.text, '{"a":1}');
  });

  Future<EditorSurfaceController> show(
    WidgetTester tester,
    String text, {
    bool readOnly = false,
  }) async {
    final controller = controllerOf(text);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IdeCodeEditor(
            controller: controller,
            path: '/w/a.json',
            focusNode: focus,
            readOnly: readOnly,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    focus.requestFocus();
    await tester.pump();
    return controller;
  }

  Future<void> rightClick(WidgetTester tester) async {
    await tester.tapAt(
      tester.getTopLeft(find.byType(EditorSurface)) + const Offset(80, 8),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('beside the chat: Format Document in its menu, with the '
      'clipboard', (tester) async {
    final controller = await show(tester, '{"a":[1]}');
    await rightClick(tester);
    for (final label in ['Format Document', 'Cut', 'Copy', 'Paste']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('Format Document'));
    await tester.pumpAndSettle();
    expect(
      controller.document.snapshot.text,
      '{\n    "a": [\n        1\n    ]\n}',
    );
  });

  testWidgets('and by its keys, Shift+Alt+F', (tester) async {
    final controller = await show(tester, '{"a":1}');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(controller.document.snapshot.text, '{\n    "a": 1\n}');
  });

  testWidgets('read only: not formatted', (tester) async {
    await show(tester, '{"a":1}', readOnly: true);
    await rightClick(tester);
    expect(find.text('Format Document'), findsNothing);
    expect(find.text('Copy'), findsOneWidget);
  });
}
