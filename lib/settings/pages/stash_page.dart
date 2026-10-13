import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../l10n/l10n.dart';
import '../../platform/app_platform.dart';
import '../../stash/stash_controller.dart';
import '../../stash/stash_settings.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import '../../workspace/window_controls.dart';
import '../user_settings.dart';
import 'settings_widgets.dart';

/// Settings → Stash (docs/stash.md; see [StashSettings] for the keys):
/// the shortcut that shows its panel from any app, and where the stashes
/// are kept.
class StashSettingsPage extends StatefulWidget {
  const StashSettingsPage({super.key, this.settings});

  /// settings.json; none under test, where choices are not kept.
  final UserSettings? settings;

  @override
  State<StashSettingsPage> createState() => _StashSettingsPageState();
}

class _StashSettingsPageState extends State<StashSettingsPage> {
  void _write(String key, Object? value) {
    final settings = widget.settings;
    if (settings == null) return;
    unawaited(
      settings.update(key, value).catchError((Object error) {
        debugPrint('$key not kept: $error');
      }),
    );
  }

  Future<void> _pickDirectory() async {
    final path = await WindowControls.pickDirectory();
    if (path != null) _write(StashSettings.directoryKey, path);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([?settings, ?StashController.current]),
      builder: (context, _) =>
          _page(context, StashSettings.parse(settings?.values ?? const {})),
    );
  }

  Widget _page(BuildContext context, StashSettings current) {
    final l10n = context.l10n;
    final mac = AppPlatform.isMacOS;
    final controller = StashController.current;
    final taken = controller?.hotkeyTaken;
    final label = StashSettings.label(current.hotkey, mac: mac);
    final root = controller?.store.root;
    return SettingsPage(
      title: l10n.settingsSectionStash,
      description: l10n.stashSettingsDescription,
      children: [
        SettingsCard(
          children: [
            SettingsRow(
              label: l10n.stashSettingsHotkey,
              description: [
                if (label.isEmpty)
                  l10n.stashSettingsHotkeyNone
                else
                  l10n.stashSettingsHotkeyCurrent(label),
                if (taken == false && label.isNotEmpty) l10n.stashSettingsHotkeyTaken,
                l10n.stashSettingsHotkeyHelp,
              ].join('\n'),
              trailing: SettingsTextField(
                value: current.hotkey,
                hint: StashSettings.defaultHotkey,
                semanticLabel: l10n.stashSettingsHotkey,
                onSubmitted: (value) {
                  final spec = value.trim().toLowerCase().replaceAll(' ', '');
                  _write(
                    StashSettings.hotkeyKey,
                    spec == StashSettings.defaultHotkey ? null : spec,
                  );
                },
              ),
            ),
          ],
        ),
        SettingsCard(
          children: [
            SettingsRow(
              label: l10n.stashSettingsDirectory,
              description: [
                current.directory ?? root ?? '~/BaoCode/Stash',
                if (current.directory != null && current.directory != root)
                  l10n.stashSettingsDirectoryRestart,
              ].join('\n'),
              trailing: SettingsButtons(
                children: [
                  if (root != null)
                    IdeButton(
                      label: l10n.stashReveal,
                      secondary: true,
                      onPressed: () => unawaited(openExternal(root)),
                    ),
                  if (WindowControls.canPickDirectory)
                    IdeButton(
                      label: l10n.stashSettingsDirectoryChange,
                      secondary: true,
                      onPressed: () => unawaited(_pickDirectory()),
                    ),
                  if (current.directory != null)
                    IdeButton(
                      label: l10n.stashSettingsDirectoryReset,
                      secondary: true,
                      onPressed: () => _write(StashSettings.directoryKey, null),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
