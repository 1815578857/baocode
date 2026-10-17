// Scratch: tools against a real app (BAO_REAL_URL). Not committed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/browser_tools.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final chrome = Platform.environment['BAO_BROWSER_LIVE'];
  final url = Platform.environment['BAO_REAL_URL'] ?? 'http://localhost:5199/';
  final host = p.absolute(
    'build/macos/Build/Products/Debug/BaoCode.app/Contents/MacOS/'
    'baocode-browser-host',
  );
  test('real', () async {
      final profile = Directory.systemTemp.createTempSync('bao-real-');
      final hosts = Directory(p.join(profile.path, 'NativeMessagingHosts'))
        ..createSync();
      File(p.join(hosts.path, '${BrowserBridge.hostName}.json'))
          .writeAsStringSync(
            jsonEncode({
              'name': BrowserBridge.hostName,
              'description': 'BaoCode',
              'path': host,
              'type': 'stdio',
              'allowed_origins': [
                for (final id in BrowserBridge.extensionIds)
                  'chrome-extension://$id/',
              ],
            }),
          );
      final sockets = Directory('/tmp').createTempSync('bao-');
      addTearDown(() => sockets.deleteSync(recursive: true));
      BrowserBridge.socketFolder = sockets.path;
      final bridge = BrowserBridge.instance;
      await bridge.start();
      BrowserTools.register();
      final browser = await Process.start(
        chrome!,
        [
          '--user-data-dir=${profile.path}',
          '--load-extension=${p.absolute('browser_extension')}',
          '--disable-features=DisableLoadExtensionCommandLineSwitch',
          '--no-first-run',
          '--no-default-browser-check',
          '--window-size=1000,700',
          'about:blank',
        ],
        environment: {'TMPDIR': sockets.path},
      );
      addTearDown(() {
        browser.kill();
        unawaited(bridge.stop());
      });
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (bridge.browsers.isEmpty && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(bridge.browsers, isNotEmpty, reason: 'the extension connects');
      final connection = bridge.browsers.first;

      var id = 0;
      Future<String> call(
        String name,
        Map<String, Object?> input, {
        bool error = false,
      }) async {
        final answer = await ClaudeSdkTools.handle({
          'jsonrpc': '2.0',
          'id': ++id,
          'method': 'tools/call',
          'params': {'name': name, 'arguments': input},
        }, ClaudeSdkCall(cwd: profile.path));
        final result = answer['result'] as Map;
        final content = (result['content'] as List).cast<Map>();
        final text = content
            .where((c) => c['type'] == 'text')
            .map((c) => c['text'])
            .join('\n');
        // ignore: avoid_print
        print('── $name ${jsonEncode(input)}\n$text');
        if (result['isError'] == true) print('!! ERROR');
        return text;
      }


      final script = jsonDecode(File('/tmp/bao-real/script.json').readAsStringSync()) as List;
      var tabId = 0;
      final vars = <String, String>{};
      for (final step in script.cast<Map>()) {
        if (step['wait'] case final num ms) {
          await Future<void>.delayed(Duration(milliseconds: ms.toInt()));
          continue;
        }
        var input = jsonEncode(step['input'] ?? {});
        input = input.replaceAll('"\$tab"', '$tabId').replaceAll('\$url', url);
        vars.forEach((k, v) => input = input.replaceAll('\$$k', v));
        final text = await call(step['tool'] as String, (jsonDecode(input) as Map).cast());
        if (step['tool'] == 'browser_open') {
          tabId = int.parse(RegExp(r'\[(\d+)\]').firstMatch(text)![1]!);
        }
        if (step['grab'] case final Map grab) {
          final m = RegExp(grab['re'] as String, multiLine: true).firstMatch(text);
          if (m != null) vars[grab['as'] as String] = m[1]!;
        }
      }
  }, skip: chrome == null, timeout: const Timeout(Duration(minutes: 6)));
}
