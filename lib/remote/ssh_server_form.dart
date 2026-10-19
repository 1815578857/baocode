// The form a server is added or edited with, from the host picker (Open
// Remote Project…'s): its address, how it signs in (a password, a key, or as
// ssh would on its own), and a host to jump through. Where the picker shows,
// at the top of the window, as if it had opened into the form.

import 'dart:io';
import 'dart:math' as math;

import 'package:bao_remote/client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../ide/ide_button.dart';
import '../ide/ide_hover.dart';
import '../ide/ide_input.dart';
import '../ide/ide_menu.dart';
import '../l10n/l10n.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/window_controls.dart';

/// What the form was saved with: the host the app knows the server as (the
/// one edited, else its address), what it says of it, its [name] (none:
/// the host), its [password] (null: as it was), and whether to [connect].
typedef SshServerFormResult = ({
  String host,
  SshServer server,
  String? name,
  String? password,
  bool connect,
});

/// Shows the form: to add a server ([host] null; at [address] when typed
/// already), or to edit [host], saved as [server] (as its text says when
/// not saved yet) and called [name]. [hasPassword] when its password is
/// kept; [jumps], the hosts it may jump through, by their names
/// ([labelOf]). Null when cancelled.
Future<SshServerFormResult?> showSshServerForm(
  BuildContext context, {
  String? host,
  String? address,
  SshServer? server,
  String? name,
  bool hasPassword = false,
  List<String> jumps = const [],
  String Function(String host)? labelOf,
}) => showGeneralDialog<SshServerFormResult>(
  context: context,
  barrierLabel: context.l10n.commonDismiss,
  barrierColor: Colors.transparent,
  pageBuilder: (context, _, _) => SshServerForm(
    host: host,
    address: address,
    server: server,
    name: name,
    hasPassword: hasPassword,
    jumps: [
      for (final jump in jumps)
        if (jump != host) jump,
    ],
    labelOf: labelOf ?? (host) => host,
  ),
);

/// `user@host[:port]` split up: null where it says nothing.
({String? user, String host, int? port}) splitAddress(String text) {
  text = text.trim();
  String? user;
  final at = text.lastIndexOf('@');
  if (at > 0) {
    user = text.substring(0, at);
    text = text.substring(at + 1);
  }
  int? port;
  // One colon: a port (an IPv6 address has more).
  final colon = text.indexOf(':');
  if (colon > 0 && colon == text.lastIndexOf(':')) {
    port = int.tryParse(text.substring(colon + 1));
    if (port != null) text = text.substring(0, colon);
  }
  return (user: user, host: text, port: port);
}

/// The private keys in [home]'s `~/.ssh`: those with a `.pub` beside them,
/// `id_*` and `*.pem`.
List<String> sshPrivateKeys([String? home]) {
  home ??= Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) return const [];
  final List<FileSystemEntity> entries;
  try {
    entries = Directory(p.join(home, '.ssh')).listSync();
  } on FileSystemException {
    return const [];
  }
  final names = {for (final entry in entries) p.basename(entry.path)};
  return [
    for (final entry in entries)
      if (entry is File)
        if (p.basename(entry.path) case final name
            when !name.endsWith('.pub') &&
                (names.contains('$name.pub') ||
                    name.startsWith('id_') ||
                    name.endsWith('.pem')))
          entry.path,
  ]..sort();
}

class SshServerForm extends StatefulWidget {
  const SshServerForm({
    super.key,
    this.host,
    this.address,
    this.server,
    this.name,
    this.hasPassword = false,
    this.jumps = const [],
    required this.labelOf,
  });

  final String? host;
  final String? address;
  final SshServer? server;
  final String? name;
  final bool hasPassword;
  final List<String> jumps;
  final String Function(String host) labelOf;

  @override
  State<SshServerForm> createState() => _SshServerFormState();
}

class _SshServerFormState extends State<SshServerForm> {
  late final _host = TextEditingController();
  late final _port = TextEditingController();
  late final _user = TextEditingController();
  late final _name = TextEditingController(text: widget.name ?? '');
  late final _password = TextEditingController();
  late final _key = TextEditingController();
  late SshAuth _auth;
  String? _jump;

  /// The messages of the fields, once saving was tried.
  final Map<String, String> _errors = {};

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    if (server != null) {
      _host.text = server.hostName;
      _port.text = '${server.port ?? 22}';
      _user.text = server.user ?? '';
      _auth = server.auth;
      _key.text = switch (server.identityFile) {
        final file? => _tilde(file),
        null => '',
      };
      _jump = server.jump;
    } else if (widget.host case final host?) {
      // Typed once: what it says, signing in as ssh would.
      final split = splitAddress(host);
      _host.text = split.host;
      _port.text = '${split.port ?? 22}';
      _user.text = split.user ?? '';
      _auth = SshAuth.auto;
    } else {
      final split = splitAddress(widget.address ?? '');
      _host.text = split.host;
      _port.text = '${split.port ?? 22}';
      _user.text = split.user ?? 'root';
      _auth = SshAuth.password;
    }
    if (_jump != null && !widget.jumps.contains(_jump)) _jump = null;
  }

  @override
  void dispose() {
    for (final controller in [_host, _port, _user, _name, _password, _key]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// A whole address pasted in the host's field: split up into the user's
  /// and the port's.
  void _hostChanged(String text) {
    if (!text.contains('@') && !text.contains(':')) return;
    final split = splitAddress(text);
    if (split.user == null && split.port == null) return;
    _host.text = split.host;
    if (split.user case final user?) _user.text = user;
    if (split.port case final port?) _port.text = '$port';
  }

  void _close([SshServerFormResult? result]) => Navigator.pop(context, result);

  void _save({required bool connect}) {
    final l10n = context.l10n;
    _hostChanged(_host.text);
    final hostName = _host.text.trim();
    final user = _user.text.trim();
    final port = int.tryParse(_port.text.trim());
    final key = _key.text.trim();
    final errors = <String, String>{
      if (hostName.isEmpty)
        'host': l10n.sshServerHostRequired
      else if (!SshTarget.isValid(hostName) || hostName.contains('@'))
        'host': l10n.sshServerHostInvalid,
      if (user.isNotEmpty && !SshTarget.isValid(user))
        'user': l10n.sshServerHostInvalid,
      if (_port.text.trim().isNotEmpty &&
          (port == null || port < 1 || port > 65535))
        'port': l10n.sshServerPortInvalid,
      if (_auth == SshAuth.key && key.isEmpty)
        'key': l10n.sshServerKeyRequired
      else if (_auth == SshAuth.key && !File(_expand(key)).existsSync())
        'key': l10n.sshServerKeyMissing,
    };
    setState(() {
      _errors
        ..clear()
        ..addAll(errors);
    });
    if (errors.isNotEmpty) return;
    final server = SshServer(
      hostName: hostName,
      port: port == null || port == 22 ? null : port,
      user: user.isEmpty ? null : user,
      auth: _auth,
      identityFile: _auth == SshAuth.key ? _expand(key) : null,
      jump: _jump,
    );
    final password = _password.text;
    _close((
      host: widget.host ?? server.address,
      server: server,
      name: _name.text.trim().isEmpty ? null : _name.text.trim(),
      password: _auth == SshAuth.password && password.isNotEmpty
          ? password
          : null,
      connect: connect,
    ));
  }

  /// [path] with `~` as the home folder.
  static String _expand(String path) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || !(path == '~' || path.startsWith('~/'))) return path;
    return p.join(home, path.substring(math.min(2, path.length)));
  }

  Future<void> _browseKey() async {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final ssh = home == null ? null : p.join(home, '.ssh');
    final files = await WindowControls.pickOpenFiles(
      directory: ssh != null && Directory(ssh).existsSync() ? ssh : null,
      multiple: false,
    );
    if (files.isEmpty || !mounted) return;
    setState(() {
      _key.text = files.single;
      _errors.remove('key');
    });
  }

  Future<void> _pickKey(Rect anchor) {
    final keys = sshPrivateKeys();
    return showIdeMenu(
      context,
      anchor: anchor,
      alignRight: true,
      entries: [
        for (final key in keys)
          IdeMenuAction(
            _tilde(key),
            checked: _expand(_key.text.trim()) == key,
            onSelected: () => setState(() {
              _key.text = _tilde(key);
              _errors.remove('key');
            }),
          ),
        if (keys.isNotEmpty) const IdeMenuSeparator(),
        IdeMenuAction(
          context.l10n.sshServerKeyBrowse,
          icon: const Icon(Codicons.folderOpened, size: 16),
          onSelected: _browseKey,
        ),
      ],
    );
  }

  /// [path] with the home folder as `~`.
  static String _tilde(String path) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || !p.isWithin(home, path)) return path;
    return '~/${p.relative(path, from: home).replaceAll(r'\', '/')}';
  }

  Future<void> _pickJump(Rect anchor) => showIdeMenu(
    context,
    anchor: anchor,
    entries: [
      IdeMenuAction(
        context.l10n.sshServerNoJump,
        checked: _jump == null,
        onSelected: () => setState(() => _jump = null),
      ),
      if (widget.jumps.isNotEmpty) const IdeMenuSeparator(),
      for (final host in widget.jumps)
        IdeMenuAction(
          _jumpLabel(host),
          checked: _jump == host,
          onSelected: () => setState(() => _jump = host),
        ),
    ],
  );

  String _jumpLabel(String host) {
    final label = widget.labelOf(host);
    return label == host ? host : '$label  ($host)';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = themeColors;
    final border = colors.get('widget.border');
    final shadow = colors.get('widget.shadow');
    final foreground = colors['editorWidget.foreground'];
    final width = math.min(560.0, MediaQuery.sizeOf(context).width - 32);
    final editing = widget.host != null;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: FocusScope(
        autofocus: true,
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 44),
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                width: width,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height - 64,
                ),
                decoration: BoxDecoration(
                  color: colors['quickInput.background'],
                  border: border == null ? null : Border.all(color: border),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    const BoxShadow(color: Color(0x26000000), blurRadius: 20),
                    if (shadow != null) BoxShadow(color: shadow, blurRadius: 8),
                  ],
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              editing
                                  ? l10n.sshServerEditTitle(
                                      widget.labelOf(widget.host!),
                                    )
                                  : l10n.sshServerAddTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: foreground,
                              ),
                            ),
                          ),
                          IdeActionButton(
                            icon: Codicons.close,
                            tooltip: l10n.dialogCloseDialog,
                            onPressed: _close,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _Field(
                              label: l10n.sshServerHost,
                              child: IdeInputBox(
                                controller: _host,
                                autofocus: !editing,
                                placeholder: l10n.sshServerHostPlaceholder,
                                semanticsLabel: l10n.sshServerHost,
                                validation: _error('host'),
                                onChanged: _hostChanged,
                                onSubmitted: (_) => _save(connect: true),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 84,
                            child: _Field(
                              label: l10n.sshServerPort,
                              child: IdeInputBox(
                                controller: _port,
                                placeholder: '22',
                                semanticsLabel: l10n.sshServerPort,
                                validation: _error('port'),
                                onSubmitted: (_) => _save(connect: true),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _Field(
                              label: l10n.sshServerUser,
                              child: IdeInputBox(
                                controller: _user,
                                placeholder: 'root',
                                semanticsLabel: l10n.sshServerUser,
                                validation: _error('user'),
                                onSubmitted: (_) => _save(connect: true),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _Field(
                              label: l10n.sshServerName,
                              child: IdeInputBox(
                                controller: _name,
                                placeholder: l10n.sshServerNamePlaceholder,
                                semanticsLabel: l10n.sshServerName,
                                onSubmitted: (_) => _save(connect: true),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _Field(
                        label: l10n.sshServerAuth,
                        child: _Segments<SshAuth>(
                          value: _auth,
                          options: [
                            (SshAuth.password, l10n.sshServerAuthPassword),
                            (SshAuth.key, l10n.sshServerAuthKey),
                            (SshAuth.auto, l10n.sshServerAuthAuto),
                          ],
                          onChanged: (auth) => setState(() => _auth = auth),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._authFields(l10n),
                      const SizedBox(height: 12),
                      _Field(
                        label: l10n.sshServerJump,
                        child: _Choice(
                          label: _jump == null
                              ? l10n.sshServerNoJump
                              : _jumpLabel(_jump!),
                          onOpen: _pickJump,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          IdeButton(
                            label: l10n.commonCancel,
                            secondary: true,
                            onPressed: _close,
                          ),
                          IdeButton(
                            label: l10n.sshServerSave,
                            secondary: true,
                            onPressed: () => _save(connect: false),
                          ),
                          IdeButton(
                            label: l10n.sshServerSaveConnect,
                            onPressed: () => _save(connect: true),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  IdeInputValidation? _error(String field) => switch (_errors[field]) {
    final message? => IdeInputValidation(message),
    null => null,
  };

  /// What the way of signing in picked asks for.
  List<Widget> _authFields(AppLocalizations l10n) => switch (_auth) {
    SshAuth.password => [
      IdeInputBox(
        controller: _password,
        obscureText: true,
        placeholder: widget.hasPassword
            ? l10n.sshServerPasswordKept
            : l10n.sshServerAuthPassword,
        semanticsLabel: l10n.sshServerAuthPassword,
        onSubmitted: (_) => _save(connect: true),
      ),
      _Hint(l10n.sshServerPasswordHint),
    ],
    SshAuth.key => [
      Builder(
        builder: (context) => IdeInputBox(
          controller: _key,
          placeholder: l10n.sshServerKeyPlaceholder,
          semanticsLabel: l10n.sshServerAuthKey,
          validation: _error('key'),
          onSubmitted: (_) => _save(connect: true),
          togglesInset: 2,
          toggles: [
            IdeActionButton(
              icon: Codicons.chevronDown,
              tooltip: l10n.sshServerKeysFound,
              size: 20,
              onPressed: () {
                final box = context.findRenderObject();
                if (box is! RenderBox) return;
                _pickKey(box.localToGlobal(Offset.zero) & box.size);
              },
            ),
          ],
        ),
      ),
      _Hint(l10n.sshServerKeyHint),
    ],
    SshAuth.auto => [_Hint(l10n.sshServerAuthAutoHint)],
  };
}

/// A field's label over it.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: themeColors['editorWidget.foreground'],
          ),
        ),
      ),
      child,
    ],
  );
}

/// A muted line under a field.
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 5),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        height: 16 / 11.5,
        color: themeColors['descriptionForeground'],
      ),
    ),
  );
}

/// One of a few [options], side by side, the one picked filled.
class _Segments<T> extends StatelessWidget {
  const _Segments({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: IdeInputColors.background,
      border: Border.all(color: IdeInputColors.border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      children: [
        for (final (option, label) in options)
          Expanded(
            child: _Segment(
              label: label,
              selected: option == value,
              onTap: () => onChanged(option),
            ),
          ),
      ],
    ),
  );
}

class _Segment extends StatefulWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? IdeButtonColors.background
                  : _hover
                  ? IdeInputColors.optionHoverBackground
                  : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 12,
                color: selected
                    ? IdeButtonColors.foreground
                    : IdeInputColors.foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A box showing what is picked, opening the choices ([onOpen], by its
/// rect) when clicked.
class _Choice extends StatefulWidget {
  const _Choice({required this.label, required this.onOpen});

  final String label;
  final ValueChanged<Rect> onOpen;

  @override
  State<_Choice> createState() => _ChoiceState();
}

class _ChoiceState extends State<_Choice> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    excludeSemantics: true,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final box = context.findRenderObject();
          if (box is! RenderBox) return;
          widget.onOpen(box.localToGlobal(Offset.zero) & box.size);
        },
        child: Container(
          height: 28,
          padding: const EdgeInsets.only(left: 6, right: 4),
          decoration: BoxDecoration(
            color: IdeInputColors.background,
            border: Border.all(
              color: _hover
                  ? IdeInputColors.focusBorder
                  : IdeInputColors.border,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: IdeInputColors.foreground,
                  ),
                ),
              ),
              Icon(
                Codicons.chevronDown,
                size: 16,
                color: IdeInputColors.foreground,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
