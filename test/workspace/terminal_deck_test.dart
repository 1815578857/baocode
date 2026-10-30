// The chat's terminals in two places, the panel under the conversation and
// the side panel's page (see workspace/terminal_deck.dart): a terminal shows
// live in both, one place its view, the other mirroring it until pressed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/terminal/terminal_service.dart';
import 'package:baocode/ide/terminal/terminal_view.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/workspace/terminal_deck.dart';

import '../ide/terminal/fake_pty.dart';
import '../ide/terminal/fake_terminal.dart';

void main() {
  testWidgets('a terminal shows live in both places: the one pressed has '
      'its keyboard and size, the other mirrors it', (tester) async {
    final terminals = TerminalService(
      root: '/p',
      backend: fakeTerminalBackend(<FakePty>[]),
    );
    addTearDown(terminals.dispose);
    final hosts = TerminalHosts();
    addTearDown(hosts.dispose);
    final shell = terminals.create();

    Widget deck(String place) => Expanded(
      key: ValueKey(place),
      child: TerminalDeck(
        place: place,
        hosts: hosts,
        terminals: terminals,
        shown: shell,
        onShow: (_) {},
        onNew: () => null,
      ),
    );
    Future<void> pump(List<String> places) => tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Material(child: Row(children: [for (final p in places) deck(p)])),
      ),
    );
    Finder viewIn(String place) => find.descendant(
      of: find.byKey(ValueKey(place)),
      matching: find.byType(TerminalView),
    );
    bool mirrors(String place) =>
        tester.widget<TerminalView>(viewIn(place)).mirror;

    await pump(['panel', 'side']);
    expect(mirrors('panel'), isFalse);
    expect(mirrors('side'), isTrue);
    expect(hosts.hostOf(shell), 'panel');

    // Pressed, the mirror becomes its view, focused; the panel mirrors it.
    await tester.tap(viewIn('side'));
    await tester.pump();
    await tester.pump();
    expect(hosts.hostOf(shell), 'side');
    expect(mirrors('side'), isFalse);
    expect(mirrors('panel'), isTrue);
    expect(shell.focusNode.hasFocus, isTrue);

    // The side panel's page closed: the panel has it again.
    await pump(['panel']);
    await tester.pump();
    expect(mirrors('panel'), isFalse);
    expect(hosts.hostOf(shell), 'panel');
  });
}
