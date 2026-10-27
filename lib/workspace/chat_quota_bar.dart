import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_session.dart';
import '../chat/floating/floating_layer.dart';
import '../ide/ide_hover.dart';
import '../kernel/agent_kernel.dart' show KernelChoiceKind;
import '../l10n/l10n.dart';
import '../models/codex/codex_quota_format.dart';
import '../models/codex/codex_service.dart';
import '../models/codex/codex_usage.dart';
import '../models/model_provider.dart';
import '../models/model_providers.dart';
import '../models/model_runtime.dart' show codexService;
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;

/// Under the composer: its branch, followed by the selected upstream's
/// accounts and how much of each one's quota is left.
class ChatQuotaBar extends StatefulWidget {
  const ChatQuotaBar({
    super.key,
    required this.session,
    required this.branch,
    this.providers,
    this.codex,
  });

  final ChatSession session;
  final Widget branch;
  final ModelProviders? providers;
  final CodexService? codex;

  @override
  State<ChatQuotaBar> createState() => _ChatQuotaBarState();
}

class _ChatQuotaBarState extends State<ChatQuotaBar>
    with WidgetsBindingObserver {
  late ModelProviders _providers;
  late CodexService _codex;
  ModelProvider? _provider;
  List<String> _accounts = [];
  bool _refreshScheduled = false;
  String? _refreshError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  void _listen() {
    _providers = widget.providers ?? ModelProviders.current;
    _codex = widget.codex ?? codexService;
    widget.session.addListener(_sessionChanged);
    _providers.addListener(_providersChanged);
    _codex.addListener(_quotaChanged);
    _readSelection();
    _requestRefresh();
  }

  void _unlisten(ChatSession session) {
    session.removeListener(_sessionChanged);
    _providers.removeListener(_providersChanged);
    _codex.removeListener(_quotaChanged);
  }

  @override
  void didUpdateWidget(ChatQuotaBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session ||
        oldWidget.providers != widget.providers ||
        oldWidget.codex != widget.codex) {
      _unlisten(oldWidget.session);
      _refreshError = null;
      _listen();
    }
  }

  /// Model changes matter; the session's streaming notifications do not.
  bool _readSelection() {
    final ref = parseModelRef(widget.session.selected(KernelChoiceKind.model));
    final selected = _providers.provider(ref?.provider);
    final provider = selected?.protocol.usesAccounts == true ? selected : null;
    final accounts = <String>[
      for (final account in provider?.accounts ?? <ProviderAccount>[])
        account.id,
    ];
    final changed =
        provider?.id != _provider?.id || !listEquals(accounts, _accounts);
    _provider = provider;
    _accounts = accounts;
    if (changed) _refreshError = null;
    return changed;
  }

  void _sessionChanged() {
    if (!_readSelection()) return;
    setState(() {});
    _requestRefresh();
  }

  void _providersChanged() {
    final changed = _readSelection();
    setState(() {});
    if (changed) _requestRefresh();
  }

  void _quotaChanged() => setState(() {});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _requestRefresh();
  }

  void _requestRefresh() {
    if (_refreshScheduled || (_provider?.accounts.isEmpty ?? true)) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (!mounted) return;
      final provider = _provider;
      if (provider == null || provider.accounts.isEmpty) return;
      unawaited(_refresh(provider, _codex));
    });
  }

  Future<void> _refresh(ModelProvider provider, CodexService service) async {
    bool current() =>
        mounted &&
        _provider?.id == provider.id &&
        service == _codex &&
        listEquals([
          for (final account in provider.accounts) account.id,
        ], _accounts);
    try {
      await service.refreshUsage(provider, force: false);
      if (current() && _refreshError != null) {
        setState(() => _refreshError = null);
      }
    } on Object catch (error) {
      if (current()) setState(() => _refreshError = '$error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unlisten(widget.session);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    if (provider == null || provider.accounts.isEmpty) return widget.branch;
    final names = [
      for (final account in provider.accounts) _shortName(account),
    ];
    return LayoutBuilder(
      // Many accounts must not push the composer out of a short split pane.
      builder: (context, constraints) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 96),
        child: SingleChildScrollView(
          primary: false,
          child: Wrap(
            spacing: 6,
            runSpacing: 2,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.min(240, constraints.maxWidth),
                ),
                child: widget.branch,
              ),
              for (final (index, account) in provider.accounts.indexed)
                Padding(
                  key: ValueKey((provider.id, account.id)),
                  padding: const EdgeInsets.only(top: 4),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.min(380, constraints.maxWidth),
                    ),
                    child: _AccountQuota(
                      account: account,
                      name:
                          names.where((name) => name == names[index]).length > 1
                          ? '${names[index]} (${index + 1})'
                          : names[index],
                      providerName: provider.name,
                      usage: _codex.usage(provider.id, account.id),
                      error:
                          _codex.error(provider.id, account.id) ??
                          _refreshError,
                      limitedUntil: _codex.limitedUntil(
                        provider.id,
                        account.id,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _shortName(ProviderAccount account) {
    final name = account.displayName.split('@').first;
    return name.characters.length > 16 ? '${name.characters.take(15)}…' : name;
  }
}

class _AccountQuota extends StatefulWidget {
  const _AccountQuota({
    required this.account,
    required this.name,
    required this.providerName,
    required this.usage,
    required this.error,
    required this.limitedUntil,
  });

  final ProviderAccount account;
  final String name;
  final String providerName;
  final CodexUsage? usage;
  final String? error;
  final DateTime? limitedUntil;

  @override
  State<_AccountQuota> createState() => _AccountQuotaState();
}

class _AccountQuotaState extends State<_AccountQuota> {
  final _focus = FocusNode();
  final _tapRegion = Object();
  bool _open = false;
  bool _hovered = false;
  bool _focused = false;

  void _setOpen(bool open) {
    if (_open == open) return;
    setState(() => _open = open);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final now = DateTime.now();
    final usage = widget.usage;
    final limited =
        (usage?.limitReached ?? false) ||
        (widget.limitedUntil?.isAfter(now) ?? false);
    final states = [
      if (!widget.account.enabled) l10n.modelsAccountDisabled,
      if (limited) l10n.modelsAccountLimited,
      if (widget.error != null) l10n.modelsAccountError,
    ];
    final windows = [
      (usage?.primary, l10n.modelsQuotaShortWindow),
      (usage?.secondary, l10n.modelsQuotaLongWindow),
    ];
    String windowName(CodexWindow? window, String fallback) {
      final name = quotaWindowName(l10n, window?.minutes);
      return name.isEmpty ? fallback : name;
    }

    final label = [
      widget.name,
      for (final (window, fallback) in windows)
        '${windowName(window, fallback)} ${window == null ? '—' : l10n.modelsQuotaRemaining(window.leftPercent.round())}',
      ...states,
    ].join(' · ');
    final detail = [
      widget.account.displayName,
      widget.providerName,
      ?usage?.plan ?? widget.account.plan,
      ?widget.account.accountId,
      ...states,
      if (usage == null || usage.windows.isEmpty)
        l10n.modelsAccountQuotaUnknown,
      for (final (window, fallback) in windows)
        [
          '${windowName(window, fallback)}: ${window == null ? '—' : l10n.modelsQuotaRemaining(window.leftPercent.round())}',
          if (window?.resetsAt case final at?) quotaResets(l10n, at, now),
        ].join(' · '),
      if (usage?.credits case final credits?) l10n.modelsQuotaCredits(credits),
      if (usage != null)
        l10n.modelsQuotaLastUpdated(
          '${MaterialLocalizations.of(context).formatShortDate(usage.at.toLocal())} '
          '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(usage.at.toLocal()))}',
        ),
      ?widget.error,
    ].join('\n');
    final color = widget.account.enabled
        ? AppColors.textMuted
        : AppColors.textFaint;
    Widget item = FocusableActionDetector(
      focusNode: _focus,
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      onFocusChange: (value) {
        if (!value) {
          _setOpen(false);
        } else {
          unawaited(Scrollable.ensureVisible(context));
        }
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _setOpen(!_open);
            return null;
          },
        ),
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            _setOpen(false);
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _focus.requestFocus();
          _setOpen(!_open);
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 22),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: _open || _hovered ? AppColors.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: _focused ? themeColors['focusBorder'] : Colors.transparent,
            ),
          ),
          child: Text.rich(
            TextSpan(
              children: [
                if (limited || widget.error != null)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Codicons.warning, size: 13, color: color),
                    ),
                  ),
                TextSpan(text: label),
              ],
            ),
            style: TextStyle(color: color, fontSize: 12, height: 1.3),
          ),
        ),
      ),
    );
    item = Semantics(
      button: true,
      label: detail,
      excludeSemantics: true,
      onTap: () {
        _focus.requestFocus();
        _setOpen(!_open);
      },
      child: item,
    );
    // Each overlay needs its own anchor node in the desktop semantics tree.
    item = Semantics(
      container: true,
      child: IdeHover(
        message: _open ? '' : detail,
        position: IdeHoverPosition.above,
        excludeFromSemantics: true,
        child: item,
      ),
    );
    return FloatingLayer(
      visible: _open,
      tapRegionGroupId: _tapRegion,
      onTapOutside: () => _setOpen(false),
      builder: (context) => IdeHoverBox(
        child: SingleChildScrollView(primary: false, child: Text(detail)),
      ),
      child: TapRegion(groupId: _tapRegion, child: item),
    );
  }
}
