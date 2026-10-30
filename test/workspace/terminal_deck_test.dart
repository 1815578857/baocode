// The chat's terminals in two places, the panel under the conversation and
// the side panel's page (see workspace/terminal_deck.dart): one terminal
// shows in one place at a time.

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
  testWidgets('a terminal shows in one place; the other says so and takes '
      'it on Show Here, or once the first place goes', (tester) async {
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
    Finder noteIn(String place) => find.descendant(
      of: find.byKey(ValueKey(place)),
      matching: find.text('This terminal is shown in another place'),
    );

    await pump(['panel', 'side']);
    expect(viewIn('panel'), findsOneWidget);
    expect(noteIn('side'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('side')),
        matching: find.text('Show Here'),
      ),
    );
    await tester.pump();
    expect(viewIn('side'), findsOneWidget);
    expect(noteIn('panel'), findsOneWidget);

    // The side panel's page closed: the panel shows it again.
    await pump(['panel']);
    await tester.pump();
    expect(viewIn('panel'), findsOneWidget);
    expect(hosts.hostOf(shell), 'panel');
  });
}
