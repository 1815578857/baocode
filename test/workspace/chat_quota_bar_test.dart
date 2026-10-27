import 'dart:ui' show PointerDeviceKind;

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/kernel/agent_kernel.dart' show KernelChoiceKind;
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/models/codex/codex_service.dart';
import 'package:baocode/models/codex/codex_usage.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/workspace/chat_branch_bar.dart';
import 'package:baocode/workspace/chat_quota_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends ChatSession {
  _Session(this.model) : super(historyCount: 0);

  String? model;

  @override
  String? selected(KernelChoiceKind kind) =>
      kind == KernelChoiceKind.model ? model : super.selected(kind);

  void select(String? value) {
    model = value;
    notifyListeners();
  }
}

class _Codex extends CodexService {
  final usages = <(String, String), CodexUsage>{};
  final errors = <(String, String), String>{};
  final limited = <(String, String), DateTime>{};
  final refreshed = <(String, bool)>[];
  String? refreshError;

  void changed() => notifyListeners();

  @override
  Future<void> refreshUsage(ModelProvider provider, {bool force = true}) async {
    refreshed.add((provider.id, force));
    if (refreshError case final error?) throw CodexException(error);
  }

  @override
  CodexUsage? usage(String providerId, String accountId) =>
      usages[(providerId, accountId)];

  @override
  String? error(String providerId, String accountId) =>
      errors[(providerId, accountId)];

  @override
  DateTime? limitedUntil(String providerId, String accountId) =>
      limited[(providerId, accountId)];

  @override
  Future<CodexLogin> login(String providerId) => throw UnimplementedError();

  @override
  Future<void> removeAccount(String providerId, String accountId) =>
      throw UnimplementedError();
}

const _alice = ProviderAccount(
  id: 'a',
  email: 'alice@example.com',
  plan: 'team',
);
const _bob = ProviderAccount(id: 'b', email: 'bob@example.com');
const _provider = ModelProvider(
  id: 'codex',
  name: 'ChatGPT',
  protocol: ProviderProtocol.codex,
  accounts: [_alice, _bob],
);

CodexUsage _usage(double short, double long) => CodexUsage(
  at: DateTime(2026, 10, 27, 12),
  primary: CodexWindow(
    usedPercent: short,
    minutes: 300,
    resetsAt: DateTime(2026, 10, 28, 12),
  ),
  secondary: CodexWindow(usedPercent: long, minutes: 10080),
);

Finder _label(String name) =>
    find.textContaining('$name ·', findRichText: true);

Future<void> _pump(
  WidgetTester tester, {
  required _Session session,
  required ModelProviders providers,
  required _Codex codex,
  double width = 720,
  double scale = 1,
  Locale locale = const Locale('en'),
  String branch = 'main',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: ChatQuotaBar(
                session: session,
                providers: providers,
                codex: codex,
                branch: ChatBranchBar(session: session, name: branch),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late _Session session;
  late ModelProviders providers;
  late _Codex codex;

  setUp(() {
    session = _Session(modelRef('codex', 'gpt'));
    providers = ModelProviders.memory(providers: [_provider]);
    codex = _Codex()
      ..usages[('codex', 'a')] = _usage(17, 50)
      ..usages[('codex', 'b')] = _usage(40, 75);
  });

  tearDown(() {
    session.dispose();
    providers.dispose();
    codex.dispose();
  });

  Future<void> pump(WidgetTester tester) =>
      _pump(tester, session: session, providers: providers, codex: codex);

  testWidgets('each account shows remaining, not used, next to the branch', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('main'), findsOneWidget);
    expect(_label('alice'), findsOneWidget);
    expect(_label('bob'), findsOneWidget);
    expect(
      find.text('alice · 5h 83% left · Weekly 50% left', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('bob · 5h 60% left · Weekly 25% left', findRichText: true),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(_label('alice')).dx,
      greaterThan(tester.getTopLeft(find.text('main')).dx),
    );
    expect(codex.refreshed, [('codex', false)]);
  });

  testWidgets('only the selected account upstream is shown', (tester) async {
    await providers.save(
      const ModelProvider(
        id: 'other',
        name: 'Other',
        protocol: ProviderProtocol.codex,
        accounts: [_alice],
      ),
    );
    codex.usages[('other', 'a')] = _usage(90, 95);
    await pump(tester);
    expect(find.textContaining('10% left', findRichText: true), findsNothing);
    session.select(modelRef('other', 'gpt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('10% left', findRichText: true), findsOneWidget);
    expect(_label('bob'), findsNothing);

    session.select('built-in-model');
    await tester.pumpAndSettle();
    expect(_label('alice'), findsNothing);
    expect(find.text('main'), findsOneWidget);
    expect(codex.refreshed, [('codex', false), ('other', false)]);
  });

  testWidgets('unknown, disabled, limited and failed accounts stay visible', (
    tester,
  ) async {
    await providers.save(
      _provider.copyWith(accounts: [_alice.copyWith(enabled: false), _bob]),
    );
    codex.usages.remove(('codex', 'a'));
    codex.errors[('codex', 'b')] = 'Sign in again.';
    codex.limited[('codex', 'b')] = DateTime.now().add(const Duration(days: 1));
    await pump(tester);
    expect(
      find.textContaining(
        'Short window — · Long window — · Disabled',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Out of quota · Account error', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('100% left', findRichText: true), findsNothing);
    expect(
      find.textContaining('bob · 5h 60% left', findRichText: true),
      findsOneWidget,
    );

    codex.usages[('codex', 'a')] = CodexUsage(
      at: DateTime(2026),
      primary: CodexWindow(usedPercent: 150, minutes: 300),
    );
    codex.changed();
    await tester.pumpAndSettle();
    expect(
      find.textContaining('5h 0% left · Long window —', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('configuration and usage updates repaint without refresh loops', (
    tester,
  ) async {
    await pump(tester);
    session.select(modelRef('codex', 'another-model'));
    codex.usages[('codex', 'a')] = _usage(30, 60);
    codex.changed();
    await tester.pumpAndSettle();
    await pump(tester);
    expect(codex.refreshed, [('codex', false)]);
    expect(
      find.textContaining('alice · 5h 70% left', findRichText: true),
      findsOneWidget,
    );

    await providers.save(_provider.copyWith(accounts: [_bob]));
    await tester.pumpAndSettle();
    expect(_label('alice'), findsNothing);
    expect(_label('bob'), findsOneWidget);
    expect(codex.refreshed, [('codex', false), ('codex', false)]);

    await providers.save(_provider.copyWith(accounts: []));
    await tester.pumpAndSettle();
    expect(_label('bob'), findsNothing);
    expect(find.byType(Wrap), findsNothing);
  });

  testWidgets('a successful resume refresh clears an earlier refresh error', (
    tester,
  ) async {
    codex.refreshError = 'Connection interrupted';
    await pump(tester);
    expect(
      find.textContaining('Account error', findRichText: true),
      findsNWidgets(2),
    );
    codex.refreshError = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Account error', findRichText: true),
      findsNothing,
    );
    expect(codex.refreshed, [('codex', false), ('codex', false)]);
  });

  testWidgets('hover and keyboard expose full account details', (tester) async {
    await pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(_label('alice')));
    await tester.pump(ideHoverDelay + const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.textContaining('alice@example.com'), findsOneWidget);
    expect(find.textContaining('Last updated'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    await mouse.removePointer();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.textContaining('alice@example.com'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.textContaining('alice@example.com'), findsNothing);
  });

  testWidgets('long identities and narrow panes wrap without losing accounts', (
    tester,
  ) async {
    await providers.save(
      _provider.copyWith(
        accounts: [
          _alice.copyWith(email: 'the-same-very-long-name@one.example'),
          _bob.copyWith(email: 'the-same-very-long-name@two.example'),
        ],
      ),
    );
    await _pump(
      tester,
      session: session,
      providers: providers,
      codex: codex,
      width: 220,
      scale: 1.7,
      branch: 'a-very-long-branch-or-folder-name-that-does-not-fit',
    );
    expect(tester.takeException(), isNull);
    expect(_label('the-same-very-l… (1)'), findsOneWidget);
    expect(_label('the-same-very-l… (2)'), findsOneWidget);
    final first = tester.getRect(_label('the-same-very-l… (1)'));
    final second = tester.getRect(_label('the-same-very-l… (2)'));
    expect(second.top, greaterThanOrEqualTo(first.bottom));
    expect(first.width, lessThanOrEqualTo(220));
    expect(second.width, lessThanOrEqualTo(220));
  });

  testWidgets('many accounts remain reachable in a short chat pane', (
    tester,
  ) async {
    final accounts = [
      for (var i = 0; i < 10; i++)
        ProviderAccount(id: 'user$i', email: 'user$i@example.com'),
    ];
    await providers.save(_provider.copyWith(accounts: accounts));
    for (final account in accounts) {
      codex.usages[('codex', account.id)] = _usage(17, 50);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              height: 300,
              child: ChatScreen(
                session: session,
                title: 'New Chat',
                windowTitleBar: false,
                start: const Text('baocode'),
                below: ChatQuotaBar(
                  session: session,
                  providers: providers,
                  codex: codex,
                  branch: ChatBranchBar(session: session, name: 'main'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final footer = find.byType(ChatQuotaBar);
    expect(tester.getSize(footer).height, lessThanOrEqualTo(96));
    final scrollable = find
        .descendant(of: footer, matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(
      _label('user9'),
      80,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(_label('user9')).overlaps(tester.getRect(footer)),
      isTrue,
    );
    await tester.tap(_label('user9'));
    await tester.pumpAndSettle();
    expect(find.textContaining('user9@example.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned details suppress hover duplicates and can scroll', (
    tester,
  ) async {
    codex.errors[('codex', 'a')] = List.filled(80, 'Request failed.').join(' ');
    await pump(tester);
    await tester.tap(_label('alice'));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(_label('alice')));
    await tester.pump(ideHoverDelay + const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.textContaining('alice@example.com'), findsOneWidget);
    final scrollable = find.descendant(
      of: find.byType(IdeHoverBox),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    await mouse.moveTo(Offset.zero);
    await mouse.removePointer();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.textContaining('alice@example.com'), findsNothing);
  });

  testWidgets('remaining labels follow the app language', (tester) async {
    await _pump(
      tester,
      session: session,
      providers: providers,
      codex: codex,
      locale: const Locale('zh'),
    );
    expect(find.textContaining('剩余 83%', findRichText: true), findsOneWidget);
    expect(find.textContaining('剩余 50%', findRichText: true), findsOneWidget);
  });
}
