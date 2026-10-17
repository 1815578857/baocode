import 'dart:io';

import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/settings/pages/browser_page.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory data;
  late UserSettings settings;

  setUp(() async {
    data = await Directory.systemTemp.createTemp('baocode-browser-page');
    settings = UserSettings(p.join(data.path, 'settings.json'));
    await settings.load();
    // Turned off, the host's manifests go: a test's own, not the user's.
    BrowserBridge.home = data.path;
  });

  tearDown(() async {
    BrowserBridge.instance.enabled = true;
    BrowserBridge.home = null;
    settings.dispose();
    await data.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100; i++) {
      if (done()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    fail('timed out');
  }

  testWidgets(
    'the switch is kept in settings.json, and the extension is there to get',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BrowserSettingsPage(settings: settings)),
        ),
      );
      await tester.pump();
      expect(find.text('Chrome Web Store'), findsOneWidget);
      expect(find.text('Developer Mode'), findsOneWidget);
      expect(find.text('Open Store'), findsOneWidget);
      expect(find.text('Download Zip'), findsOneWidget);
      if (!Platform.isMacOS) return;

      // Never connected: it says to get the extension.
      expect(find.text("The extension isn't installed"), findsOneWidget);

      await tester.tap(find.text('Let Agents Use the Browser'));
      await settle(tester, () => settings[BrowserBridge.settingKey] == false);
      expect(BrowserBridge.instance.enabled, isFalse);
      await tester.pump();
      expect(find.text('Status'), findsNothing);

      await tester.tap(find.text('Let Agents Use the Browser'));
      await settle(
        tester,
        () => !settings.values.containsKey(BrowserBridge.settingKey),
      );
      expect(BrowserBridge.instance.enabled, isTrue);
    },
  );
}
