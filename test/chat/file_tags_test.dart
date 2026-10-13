import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:baocode/chat/side_panel/file_open.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/material_file_icons.dart';

class _Feed extends ChangeNotifier implements ChatFeed {
  _Feed(this.items);

  final List<ChatItem> items;

  @override
  int get itemCount => items.length;
  @override
  ChatItem itemAt(int index) => items[index];
  @override
  bool get isStreaming => false;
  @override
  bool get isUnprompted => false;
  @override
  bool get canEditMessages => false;
  @override
  ({int index, ComposerDraft draft})? get editing => null;
  @override
  set editing(({int index, ComposerDraft draft})? value) {}
  @override
  void editMessage(int index, ComposerMessage message) {}
  @override
  VoidCallback? moveToBackgroundAt(int index) => null;
  @override
  VoidCallback? stopAt(int index) => null;
}

/// A pixel.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// A desktop's: a right click brings up the selection's menu.
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  final opened = <String>[];
  final requests = <FileOpenRequest>[];
  final read = <String>[];

  Future<void> pump(
    WidgetTester tester,
    List<ChatItem> items, {
    bool local = true,
  }) async {
    opened.clear();
    requests.clear();
    read.clear();
    final existence = FileExistence((_) async => true);
    addTearDown(existence.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: FileOpenScope(
            root: '/p',
            onOpen: (request) {
              opened.add(request.path);
              requests.add(request);
            },
            existence: existence,
            local: local,
            readBytes: (path) async {
              read.add(path);
              return Uint8List.fromList(_png);
            },
            child: ChatHistoryView(feed: _Feed(items)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> rightClick(WidgetTester tester, Offset at) async {
    await tester.tapAt(
      at,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  final screenshots = [
    UserMessageItem(text: 'Check it'),
    AssistantTextItem(
      'Done.\n\n[旧版截图](shots/old.png) · [新版截图](shots/new.png) · '
      '[验收结果](out/result.json)',
    ),
  ];

  testWidgets('an image the conversation links to is an image\'s tag, '
      'which a click shows in the tab of what was looked at last', (
    tester,
  ) async {
    await pump(tester, screenshots);

    expect(find.byType(FileImageChip), findsNWidgets(2));
    expect(find.text('旧版截图'), findsOneWidget);
    // The other file is a link still.
    expect(find.byType(FileIcon), findsOneWidget);

    await tester.tap(find.text('旧版截图'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(opened, ['/p/shots/old.png']);
    expect(requests.single.preview, isTrue);
    expect(requests.single.readOnly, isTrue);
  }, variant: _desktop);

  testWidgets('its right click has the file\'s menu, with the image\'s '
      'own', (tester) async {
    await pump(tester, screenshots);
    await rightClick(tester, tester.getCenter(find.text('新版截图')));

    expect(tester.takeException(), isNull);
    for (final item in ['Preview', 'Open', 'Copy Image', 'Copy Path']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, ['/p/shots/new.png']);
  }, variant: _desktop);

  testWidgets('a web page here opens in the browser, from its menu too', (
    tester,
  ) async {
    final report = [
      UserMessageItem(text: 'Where is it?'),
      AssistantTextItem('See [the report](out/report.html).'),
    ];
    await pump(tester, report);
    final scope = tester.widget<FileOpenScope>(find.byType(FileOpenScope));
    expect(scope.opensInBrowser('/p/out/report.html'), isTrue);
    await rightClick(
      tester,
      tester.getCenter(find.byType(FileIcon)) + const Offset(30, 0),
    );
    expect(find.text('Open in Browser'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);

    // A remote project's opens as other files.
    await pump(tester, report, local: false);
    final remote = tester.widget<FileOpenScope>(find.byType(FileOpenScope));
    expect(remote.opensInBrowser('/p/out/report.html'), isFalse);
  }, variant: _desktop);

  testWidgets('an attached image\'s right click offers to show and copy '
      'it', (tester) async {
    await pump(tester, [
      UserMessageItem(
        text: 'Like this [Image #3]',
        images: [
          ImageAttachment(
            bytes: Uint8List.fromList(_png),
            mediaType: 'image/png',
            number: 3,
          ),
        ],
      ),
    ]);
    await rightClick(
      tester,
      tester.getCenter(find.byType(ComposerImageChip).first),
    );

    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Copy Image'), findsOneWidget);
  }, variant: _desktop);
}
