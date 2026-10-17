import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../browser/browser_bridge.dart';
import '../../browser/extension_store.dart';
import '../../ide/ide_button.dart';
import '../../l10n/l10n.dart';
import '../../theme/codicons.dart';
import '../user_settings.dart';
import 'settings_widgets.dart';

/// Settings → Browser: whether the agents may use the user's browsers
/// (settings.json's `browser.enabled`, see [BrowserBridge.enabled]), which
/// are connected, and the extension to get: from the Chrome Web Store, or
/// as a zip to load unpacked (see [ExtensionStore]).
class BrowserSettingsPage extends StatelessWidget {
  const BrowserSettingsPage({super.key, this.settings, this.browsers});

  /// settings.json; none under test, where the choice is not kept.
  final UserSettings? settings;

  /// The bridge to the browsers; the app's by default.
  final BrowserBridge? browsers;
  BrowserBridge get bridge => browsers ?? BrowserBridge.instance;

  void _enable(bool on) {
    bridge.enabled = on;
    final settings = this.settings;
    if (settings == null) return;
    unawaited(
      settings.update(BrowserBridge.settingKey, on ? null : false).catchError((
        Object error,
      ) {
        // A settings file that does not parse is left as it is; its
        // error is shown.
        debugPrint('${BrowserBridge.settingKey} not kept: $error');
      }),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: bridge,
    builder: (context, _) => _page(context),
  );

  Widget _page(BuildContext context) {
    final l10n = context.l10n;
    final bridge = this.bridge;
    return SettingsPage(
      title: l10n.settingsSectionBrowser,
      description: l10n.browserSettingsDescription,
      children: [
        if (!bridge.supported)
          SettingsCard(
            children: [SettingsRow(label: l10n.browserSettingsMacOSOnly)],
          )
        else ...[
          SettingsCard(
            children: [
              SettingsSwitchRow(
                label: l10n.browserSettingsEnabled,
                description: l10n.browserSettingsEnabledDescription,
                value: bridge.enabled,
                onChanged: _enable,
              ),
            ],
          ),
          if (bridge.enabled)
            SettingsGroup(
              title: l10n.browserSettingsStatus,
              children: [
                for (final (label, description) in status(l10n, bridge))
                  SettingsRow(label: label, description: description),
              ],
            ),
        ],
        SettingsGroup(
          title: l10n.browserSettingsInstall,
          children: [
            SettingsRow(
              label: l10n.browserSettingsStore,
              description: l10n.browserSettingsStoreDescription,
              trailing: IdeButton(
                label: l10n.browserSettingsStoreOpen,
                icon: Codicons.linkExternal,
                onPressed: () => unawaited(ExtensionStore.openPage()),
              ),
            ),
            SettingsRow(
              label: l10n.browserSettingsUnpacked,
              description: l10n.browserSettingsUnpackedDescription,
              trailing: IdeButton(
                label: l10n.browserSettingsUnpackedDownload,
                icon: Codicons.cloudDownload,
                secondary: true,
                onPressed: () => unawaited(ExtensionStore.openZip()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// What the status group says, a row each: the browsers connected and
  /// those whose extension speaks another protocol, or why there is none.
  @visibleForTesting
  static List<(String, String?)> status(
    AppLocalizations l10n,
    BrowserBridge bridge,
  ) {
    if (bridge.otherApp) return [(l10n.browserOtherApp, null)];
    final browsers = bridge.browsers;
    final mismatched = bridge.mismatched;
    if (browsers.isEmpty && mismatched.isEmpty) {
      return [
        bridge.connectedBefore
            ? (
                l10n.browserSettingsNotRunning,
                l10n.browserSettingsNotRunningDescription,
              )
            : (
                l10n.browserSettingsNotInstalled,
                l10n.browserSettingsNotInstalledDescription,
              ),
      ];
    }
    return [
      for (final browser in browsers)
        (
          l10n.browserSettingsConnected(browser.browser ?? ''),
          l10n.browserSettingsExtensionVersion(browser.version ?? '?'),
        ),
      for (final browser in mismatched)
        (
          l10n.browserSettingsIncompatible(browser.browser ?? ''),
          browser.protocol < BrowserBridge.protocol
              ? l10n.browserSettingsExtensionOld
              : l10n.browserSettingsAppOld,
        ),
    ];
  }
}
