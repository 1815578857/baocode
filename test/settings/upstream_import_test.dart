import 'dart:math';

import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/models/featured_upstreams.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/models/upstream_import.dart';
import 'package:baocode/settings/pages/featured_upstreams_strip.dart';
import 'package:baocode/settings/pages/models_page.dart';
import 'package:baocode/settings/pages/upstream_import_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _featured = [
  for (final (id, name) in [('alpha', 'Alpha API'), ('beta', 'Beta Relay')])
    FeaturedUpstream(
      id: id,
      name: name,
      url: Uri.parse('https://$id.example.com/register?aff=bao'),
      description: {'en': '$name, cheaply'},
      hosts: ['api.$id.example.com'],
    ),
];

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  late MemorySecretStore secrets;
  late ModelProviders providers;

  setUp(() {
    secrets = MemorySecretStore();
    providers = ModelProviders.memory(secrets: secrets);
  });

  group('the featured row', () {
    testWidgets('a card of each, then one for a site to be listed; a click '
        'opens its link', (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        _app(
          FeaturedUpstreamsStrip(
            upstreams: Future.value(_featured),
            random: Random(1),
            open: opened.add,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Alpha API'), findsOneWidget);
      expect(find.text('Beta Relay, cheaply'), findsOneWidget);
      expect(find.text('Your site here'), findsOneWidget);
      expect(find.text('Why am I seeing this?'), findsOneWidget);

      await tester.tap(find.text('Alpha API'));
      expect(
        opened.single.toString(),
        'https://alpha.example.com/register?aff=bao',
      );
      await tester.tap(find.text('Your site here'));
      expect(opened.last, Uri.parse('https://baocode.dev/upstreams'));
    });

    testWidgets('the order is drawn by chance', (tester) async {
      final many = [
        for (var i = 0; i < 8; i++)
          FeaturedUpstream(
            id: 'u$i',
            name: 'Upstream $i',
            url: Uri.parse('https://u$i.example.com'),
          ),
      ];
      Future<List<String>> order(int seed) async {
        await tester.pumpWidget(
          _app(
            FeaturedUpstreamsStrip(
              key: ValueKey(seed),
              upstreams: Future.value(many),
              random: Random(seed),
            ),
          ),
        );
        await tester.pump();
        final texts = tester
            .widgetList<Text>(find.textContaining('Upstream '))
            .map((text) => text.data!)
            .toList();
        return texts;
      }

      // Those in sight first, which a draw changes.
      expect(await order(1), isNot(await order(2)));
    });

    testWidgets('Settings → Models shows it under the title, what the page '
        'is about in a hover by it', (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          ModelsSettingsPage(
            providers: providers,
            featured: Future.value(_featured),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Alpha API'), findsOneWidget);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.modelsDescription), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is IdeHover && w.message == l10n.modelsDescription,
        ),
        findsOneWidget,
      );
    });
  });

  group('the import', () {
    Future<String?> run(
      WidgetTester tester,
      String link, {
      String? button,
      String? rename,
    }) async {
      String? result;
      var done = false;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showUpstreamImportDialog(
                  context,
                  UpstreamImport.parse(link)!,
                  providers: providers,
                  featured: Future.value(_featured),
                );
                done = true;
              },
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      if (rename != null) {
        await tester.enterText(
          find.byWidgetPredicate(
            (w) => w is EditableText && w.controller.text == 'Alpha',
          ),
          rename,
        );
        await tester.pump();
      }
      await tester.tap(find.text(button ?? 'Cancel').last);
      await tester.pumpAndSettle();
      expect(done, isTrue);
      return result;
    }

    const link =
        'baocode://provider/import?v=1&name=Alpha&protocol=anthropic'
        '&url=https%3A%2F%2Fapi.alpha.example.com&key=sk-alpha-1234567890';

    testWidgets('nothing is added unless the user says yes', (tester) async {
      final id = await run(tester, link);
      expect(id, isNull);
      expect(providers.providers, isEmpty);
    });

    testWidgets('shows what it imports', (tester) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showUpstreamImportDialog(
                context,
                UpstreamImport.parse(link)!,
                providers: providers,
                featured: Future.value(_featured),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(
        find.text('Import an upstream from api.alpha.example.com?'),
        findsOneWidget,
      );
      expect(
        find.textContaining('https://api.alpha.example.com'),
        findsOneWidget,
      );
      expect(find.textContaining('Key: sk-alp…7890'), findsOneWidget);
      expect(find.textContaining('sk-alpha-1234567890'), findsNothing);
      expect(
        find.textContaining('Listed in BaoCode as Alpha API.'),
        findsOneWidget,
      );
    });

    testWidgets('added on yes, its key in the keychain', (tester) async {
      final id = await run(tester, link, button: 'Import', rename: 'My Alpha');
      final provider = providers.provider(id)!;
      expect(provider.name, 'My Alpha');
      expect(provider.baseUrl, 'https://api.alpha.example.com');
      expect(provider.protocol, ProviderProtocol.anthropic);
      expect(provider.disableNonessentialTraffic, isTrue);
      expect(await secrets.read(provider.keyRef), 'sk-alpha-1234567890');
      expect(provider.toJson().toString(), isNot(contains('sk-alpha')));
    });

    testWidgets('one there already gets the new key', (tester) async {
      await providers.save(
        const ModelProvider(
          id: 'alpha',
          name: 'Old Alpha',
          baseUrl: 'https://api.alpha.example.com/v1',
        ),
      );
      final id = await run(tester, link, button: "Update Old Alpha's Key");
      expect(id, 'alpha');
      expect(providers.providers, hasLength(1));
      expect(await secrets.read('provider.alpha'), 'sk-alpha-1234567890');
    });

    testWidgets('or is kept, the import added beside it', (tester) async {
      await providers.save(
        const ModelProvider(
          id: 'alpha',
          name: 'Old Alpha',
          baseUrl: 'https://api.alpha.example.com',
        ),
      );
      final id = await run(tester, link, button: 'Add as New Upstream');
      expect(id, isNot('alpha'));
      expect(providers.providers, hasLength(2));
      expect(await secrets.read('provider.alpha'), isNull);
    });
  });

  testWidgets('an upstream imported opens on Settings → Models', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await providers.save(
      const ModelProvider(
        id: 'gw',
        name: 'Gateway',
        baseUrl: 'https://gw.example.com',
      ),
    );
    ModelsSettingsPage.reveal.value = 'gw';
    await tester.pumpWidget(
      _app(
        ModelsSettingsPage(
          providers: providers,
          featured: Future.value(const []),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Connection'), findsOneWidget);
    expect(ModelsSettingsPage.reveal.value, isNull);
  });
}
