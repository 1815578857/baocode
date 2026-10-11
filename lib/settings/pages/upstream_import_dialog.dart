import 'package:flutter/widgets.dart';

import '../../ide/ide_dialog.dart';
import '../../l10n/l10n.dart';
import '../../models/featured_upstreams.dart';
import '../../models/model_providers.dart';
import '../../models/upstream_import.dart';
import 'models_page.dart';

/// Asks whether to add the upstream a site handed over ([UpstreamImport]):
/// its name (to change), where requests go, how, and its key masked; then
/// adds it, or, when it is one there already, gives that one the key.
/// Nothing is added without the user's yes. Completes with the upstream's
/// id; null when the user said no.
Future<String?> showUpstreamImportDialog(
  BuildContext context,
  UpstreamImport import, {
  ModelProviders? providers,
  Future<List<FeaturedUpstream>>? featured,
}) async {
  final store = providers ?? ModelProviders.current;
  final listed = FeaturedUpstream.at(
    import.host,
    await (featured ?? FeaturedUpstream.load()),
  );
  if (!context.mounted) return null;
  final l10n = context.l10n;
  final existing = import.existingIn(store.providers);
  final hasKey = import.key.isNotEmpty;
  final detail = [
    '${ModelsSettingsPage.protocolName(context, import.protocol)} · '
        '${import.baseUrl}',
    l10n.modelsImportKey(hasKey ? import.maskedKey : l10n.modelsImportNoKey),
    if (listed != null) l10n.modelsImportListed(listed.name),
    if (existing != null) l10n.modelsImportExisting(existing.name),
    '',
    l10n.modelsImportWarning,
  ].join('\n');
  final buttons = [
    if (existing == null)
      l10n.modelsImportAdd
    else ...[
      hasKey
          ? l10n.modelsImportUpdateKey(existing.name)
          : l10n.modelsImportOpenExisting(existing.name),
      l10n.modelsImportAsNew,
    ],
  ];
  final result = await showIdeInputDialog(
    context,
    message: l10n.modelsImportTitle(import.host),
    detail: detail,
    buttons: buttons,
    inputs: [
      IdeDialogInput(
        placeholder: l10n.modelsImportNamePlaceholder,
        value: import.name,
      ),
    ],
    type: IdeDialogType.question,
  );
  if (result == null) return null;
  if (existing != null && result.button == 0) {
    if (hasKey) await store.setKey(existing.id, import.key);
    return existing.id;
  }
  final typed = result.values.firstOrNull?.trim() ?? '';
  final name = typed.isEmpty ? import.name : typed;
  final id = store.newId(name);
  await store.save(
    UpstreamImport(
      name: name,
      protocol: import.protocol,
      baseUrl: import.baseUrl,
    ).toProvider(id),
  );
  if (hasKey) await store.setKey(id, import.key);
  return id;
}
