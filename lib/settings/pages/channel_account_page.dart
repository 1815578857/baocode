import 'dart:async';

import 'package:flutter/material.dart';

import '../../channel/account/account_api.dart';
import '../../channel/account/channel_account.dart';
import '../../channel/channel_gate.dart';
import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../ide/ide_menu.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

/// Settings → Account, the channel build's in place of Models: the user
/// signed in to their channel's site, their balance there, new
/// conversations' model, and their keys, one in use (lib/channel/account/).
class ChannelAccountPage extends StatefulWidget {
  const ChannelAccountPage({super.key, this.gate});

  /// The app's; none on the web, or before it knows its channel.
  final ChannelGate? gate;

  @override
  State<ChannelAccountPage> createState() => _ChannelAccountPageState();
}

class _ChannelAccountPageState extends State<ChannelAccountPage> {
  ChannelAccount? _readFor;

  /// The keys read once a page is open on the account: they are not kept.
  void _readKeys(ChannelAccount account) {
    if (_readFor == account) return;
    _readFor = account;
    if (account.signedIn && !account.busy) unawaited(account.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final gate = widget.gate;
    if (gate == null) return _unavailable(context);
    return ListenableBuilder(
      listenable: gate,
      builder: (context, _) {
        final account = gate.account;
        if (account == null) return _unavailable(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _readKeys(account);
        });
        return _AccountView(
          account: account,
          channel: gate.channel?.info.name ?? account.channelName,
        );
      },
    );
  }

  Widget _unavailable(BuildContext context) {
    final l10n = context.l10n;
    return SettingsPage(
      title: l10n.channelAccountTitle,
      description: l10n.channelAccountUnavailable,
      children: const [],
    );
  }
}

class _AccountView extends StatelessWidget {
  const _AccountView({required this.account, required this.channel});

  final ChannelAccount account;
  final String channel;

  Future<void> _signOut(BuildContext context) async {
    final l10n = context.l10n;
    final answer = await showIdeDialog(
      context,
      message: l10n.channelAccountSignOutTitle,
      detail: l10n.channelAccountSignOutDetail(channel),
      buttons: [l10n.channelAccountSignOut],
    );
    if (answer == 0) await account.signOut();
  }

  Future<void> _create(BuildContext context) async {
    final l10n = context.l10n;
    final result = await showIdeInputDialog(
      context,
      message: l10n.channelAccountCreateKey,
      buttons: [l10n.channelAccountCreateKey],
      inputs: [
        IdeDialogInput(
          placeholder: l10n.channelAccountKeyName,
          value: ChannelAccount.keyName,
        ),
      ],
      type: IdeDialogType.info,
    );
    if (result == null || result.button != 0) return;
    final name = result.values.first.trim();
    await account.create(name.isEmpty ? ChannelAccount.keyName : name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) {
        final profile = account.profile;
        final error = account.error;
        return SettingsPage(
          title: l10n.channelAccountTitle,
          description: channel,
          children: [
            SettingsCard(
              children: [
                if (!account.signedIn)
                  SettingsRow(
                    label: l10n.channelAccountSignedOut,
                    trailing: IdeButton(
                      label: l10n.channelWelcomeSignIn,
                      spinning: account.signingIn,
                      onPressed: account.signingIn
                          ? null
                          : () => unawaited(account.signIn(title: channel)),
                    ),
                  )
                else
                  _ProfileRow(
                    profile: profile,
                    busy: account.busy,
                    onRefresh: () => unawaited(account.refresh()),
                    onSignOut: () => unawaited(_signOut(context)),
                  ),
                SettingsRow(
                  label: account.site.url.host,
                  trailing: IdeButton(
                    label: l10n.channelAccountOpenSite,
                    icon: Codicons.linkExternal,
                    secondary: true,
                    onPressed: () =>
                        unawaited(openExternal('${account.site.url}')),
                  ),
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Text(
                  l10n.channelAccountFailed('$error'),
                  style: TextStyle(color: AppColors.caution, fontSize: 12),
                ),
              ),
            if (account.signedIn) ...[
              SettingsGroup(
                title: l10n.channelAccountDefaultModel,
                children: [_DefaultModelRow(account: account)],
              ),
              _Keys(account: account, onCreate: () => _create(context)),
            ],
          ],
        );
      },
    );
  }
}

/// Who is signed in, and what is left on their account.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.profile,
    required this.busy,
    required this.onRefresh,
    required this.onSignOut,
  });

  final AccountProfile? profile;
  final bool busy;
  final VoidCallback onRefresh;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = profile?.email ?? profile?.name ?? '';
    final balance = profile?.balance;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Avatar(name: name),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name.isEmpty ? '—' : name, style: SettingsText.label),
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '${l10n.channelAccountBalance}  '),
                        TextSpan(
                          text: balance == null
                              ? '—'
                              : '\$${balance.toStringAsFixed(2)}',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    style: SettingsText.description,
                  ),
                ],
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IdeButton(
                label: l10n.channelAccountRefresh,
                icon: Codicons.refresh,
                spinning: busy,
                secondary: true,
                onPressed: busy ? null : onRefresh,
              ),
              const SizedBox(width: 8),
              IdeButton(
                label: l10n.channelAccountSignOut,
                icon: Codicons.signOut,
                secondary: true,
                onPressed: busy ? null : onSignOut,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.accent.withValues(alpha: .16),
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: AppColors.accent,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DefaultModelRow extends StatelessWidget {
  const _DefaultModelRow({required this.account});

  final ChannelAccount account;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final models = account.models;
    if (models.isEmpty) {
      return SettingsRow(
        label: l10n.channelAccountDefaultModel,
        description: l10n.channelAccountNoModels,
      );
    }
    final current = account.defaultModel;
    final shown =
        models.where((m) => m.id == current).firstOrNull?.displayName ??
        models.first.displayName;
    return SettingsRow(
      label: l10n.channelAccountDefaultModel,
      trailing: SettingsDropdown(
        current: shown,
        width: 240,
        semanticLabel: '${l10n.channelAccountDefaultModel}: $shown',
        entries: () => [
          for (final model in models)
            IdeMenuAction(
              model.displayName,
              checked: model.id == current,
              onSelected: () => unawaited(account.setDefaultModel(model.id)),
            ),
        ],
      ),
    );
  }
}

/// The user's keys, the one in use marked; another put to use, or one
/// made.
class _Keys extends StatelessWidget {
  const _Keys({required this.account, required this.onCreate});

  final ChannelAccount account;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final keys = account.keys;
    final inUse = account.inUse?.id;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 4, 8),
            child: Row(
              children: [
                Text(l10n.channelAccountKeys, style: SettingsText.heading),
                if (keys != null) ...[
                  const SizedBox(width: 8),
                  _Count(keys.length),
                ],
                const Spacer(),
                IdeButton(
                  label: l10n.channelAccountCreateKey,
                  icon: Codicons.add,
                  secondary: true,
                  onPressed: account.busy ? null : onCreate,
                ),
              ],
            ),
          ),
          SettingsCard(
            children: [
              if (keys == null)
                const SizedBox(height: 44)
              else if (keys.isEmpty)
                SettingsRow(label: l10n.channelAccountNoKeys)
              else
                for (final key in keys)
                  SettingsRow(
                    label: key.name,
                    description: key.masked,
                    trailing: key.id == inUse
                        ? _InUse(l10n.channelAccountInUse)
                        : IdeButton(
                            label: l10n.channelAccountUseKey,
                            secondary: true,
                            onPressed: account.busy
                                ? null
                                : () => unawaited(account.use(key)),
                          ),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.count);

  final int count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      color: AppColors.hover,
      borderRadius: BorderRadius.circular(9),
    ),
    child: Text(
      '$count',
      style: TextStyle(color: AppColors.textMuted, fontSize: 11),
    ),
  );
}

class _InUse extends StatelessWidget {
  const _InUse(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.added.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Codicons.check, size: 13, color: AppColors.added),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: AppColors.added, fontSize: 12)),
      ],
    ),
  );
}
