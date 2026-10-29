import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart' show builtInSticker;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_models.dart';
import '../chat/chat_session.dart';
import '../images/image_tools.dart' show ImageTools;
import '../kernel/agent_kernel.dart';
import '../kernel/claude_code/claude_sdk_tools.dart';
import '../kernel/kernel_registry.dart';
import '../kernel/queued_messages.dart';
import '../link/chat_codec.dart';
import '../link/link_platform.dart';
import '../workspace/preference_store.dart';
import '../workspace/workspace.dart';
import 'bot.dart';
import 'bot_folders.dart';
import 'bot_pacer.dart';
import 'bot_prompt.dart';
import 'bot_tools.dart';

/// A bot's picture: its bytes, and their media type.
typedef BotAvatarImage = ({Uint8List bytes, String type});

/// The user's bots: agents of their own making that chat as a person does
/// (see bot.dart), each a conversation in a folder of its own, which the
/// sidebar does not list. Their tools are theirs ([ClaudeSdkGate]): those
/// of the abilities the user turned on; and they write first of what
/// happens to the agents, paced ([BotPacer]).
class Bots extends ChangeNotifier implements ClaudeSdkGate {
  Bots({
    required this.workspace,
    BotFolders? folders,
    this.store,
    DateTime Function()? clock,
    this.chinese = false,
    this.longRun = const Duration(minutes: 30),
    Future<String?> Function()? computer,
  }) : folders = folders ?? BotFolders.data(),
       _clock = clock ?? DateTime.now,
       _computerName = computer ?? _thisComputer;

  final Workspace workspace;
  final BotFolders folders;

  /// Where the list of them is kept.
  final PreferenceStore? store;
  final DateTime Function() _clock;

  /// Whether the assistant made at first is named and told in Chinese.
  final bool chinese;

  /// How long an agent runs before the bots are told it does.
  final Duration longRun;

  final Future<String?> Function() _computerName;

  /// The computer the bots live on, as the user named it: for them to know.
  String? computer;

  static Future<String?> _thisComputer() async =>
      (await LinkPlatform.current()?.device())?.name;

  /// The settings its agent runs with: it asks nothing (its tools are
  /// allowed, all else refused), and works as an agent, not in Plan.
  static const settings = {'mode': 'agent', 'permission': 'dontAsk'};

  List<Bot> _bots = [];
  List<Bot> get bots => List.unmodifiable(_bots);

  final Map<String, BotPacer> _pacers = {};
  Timer? _timer;

  /// What each bot meant to come back to, by its id, soonest first.
  final Map<String, List<BotLater>> _laters = {};

  /// The most a bot may have waiting to come back to.
  static const maxLaters = 5;

  /// The agents each bot started or wrote to, by its id: those it is
  /// told of, the assistant aside (told of all).
  final Map<String, List<String>> _watching = {};

  /// The most agents a bot is told of for having started or written to.
  static const maxWatching = 40;

  /// Who the user is, as they put it on their phone.
  BotUser _me = const BotUser();

  /// The bots to start again once they stop answering: changed meanwhile.
  final Set<String> _restartWhenIdle = {};

  /// The last turn end of each bot's the user has seen, by its id.
  final Map<String, int> _seen = {};

  /// How each agent stood when last looked at, to tell what changed.
  final Map<AgentThread, ThreadStatus> _statuses = {};

  /// Since when each agent at work has run; and those told of already.
  final Map<AgentThread, DateTime> _runningSince = {};
  final Set<AgentThread> _toldRunning = {};
  Timer? _runningTimer;

  bool _started = false;

  /// Each bot's conversation followed, for the phones to hear of each of
  /// its messages (not only of its turns' ends): what it was at last.
  final Map<ChatSession, VoidCallback> _followed = {};

  Future<void> start() async {
    final root = folders.root;
    if (root == null || _started) return;
    _started = true;
    try {
      computer = await _computerName();
    } on Object catch (error) {
      debugPrint('bots: no computer name: $error');
    }
    final kept = await store?.read() ?? const {};
    _bots = [
      for (final json in (kept['bots'] as List?) ?? const [])
        ?Bot.fromJson(json, root: root),
    ];
    if (kept['later'] case final Map<String, Object?> laters) {
      for (final MapEntry(:key, :value) in laters.entries) {
        _laters[key] = [
          for (final json in value is List ? value : const [])
            ?BotLater.fromJson(json),
        ];
      }
    }
    if (kept['watching'] case final Map<String, Object?> watching) {
      for (final MapEntry(:key, :value) in watching.entries) {
        _watching[key] = [
          for (final id in value is List ? value : const []) ?id as String?,
        ];
      }
    }
    _me = BotUser.fromJson(kept['me']);
    if (!_bots.any((bot) => bot.assistant)) {
      final defaults = assistantDefaults(chinese: chinese);
      _bots.insert(
        0,
        Bot(
          id: 'assistant',
          name: defaults.name,
          folder: p.join(root, 'assistant'),
          identity: defaults.identity,
          abilities: BotAbility.values.toSet(),
          assistant: true,
          created: _clock(),
        ),
      );
      _save();
    }
    for (final bot in _bots) {
      folders.make(bot.folder);
    }
    workspace.agentSetup = _setup;
    ClaudeSdkTools.gate = this;
    BotTools.register(this);
    // Each with its conversation, for the phones to open from the first.
    _bots.forEach(threadFor);
    workspace.addListener(_watch);
    _watch();
    _schedule();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_started) {
      workspace.removeListener(_watch);
      if (identical(ClaudeSdkTools.gate, this)) ClaudeSdkTools.gate = null;
      BotTools.unregister();
      workspace.agentSetup = null;
    }
    for (final MapEntry(key: session, value: listener) in _followed.entries) {
      session.removeListener(listener);
    }
    _followed.clear();
    _timer?.cancel();
    _runningTimer?.cancel();
    super.dispose();
  }

  void _save() => unawaited(
    store?.write({
      'bots': [for (final bot in _bots) bot.toJson()],
      'later': {
        for (final MapEntry(:key, :value) in _laters.entries)
          if (value.isNotEmpty)
            key: [for (final later in value) later.toJson()],
      },
      'watching': {
        for (final MapEntry(:key, :value) in _watching.entries)
          if (value.isNotEmpty) key: value,
      },
      if (!_me.isEmpty) 'me': _me.toJson(),
    }),
  );

  /// The time, as the bots have it.
  DateTime get now => _clock();

  Bot? byId(String id) => _bots.where((bot) => bot.id == id).firstOrNull;

  /// The bot whose folder [cwd] is.
  Bot? botAt(String cwd) => _bots.where((bot) => bot.folder == cwd).firstOrNull;

  AgentSetup? _setup(String path) => switch (botAt(path)) {
    final bot? => AgentSetup(
      workspace: () => KernelWorkspace(
        folders: const [],
        instructions: botInstructions(
          bot,
          user: _me,
          memory: folders.readMemory(bot.folder),
          self: selfNotes(bot),
          computer: computer,
          model: modelOf(bot),
          now: _clock(),
          imageModel:
              ClaudeSdkTools.called(
                'mcp__${ClaudeSdkTools.server}__${ImageTools.name}',
              ) !=
              null,
        ),
        // Told only who it is and how it talks: no coding agent's prompt.
        ownPrompt: true,
        // Its own tools, and the web's, its own to use; the tool search,
        // for the browser's, which are deferred.
        tools: [...webTools, if (bot.can(BotAbility.browser)) 'ToolSearch'],
        allowedTools: webTools,
        // What the user writes while it talks, taken up as it does: as a
        // person hears what is said meanwhile; and shown where they wrote
        // it.
        queuedMessages: QueuedMessages.duringTurn,
        queuedInPlace: true,
      ),
      settings: {...settings, 'model': ?bot.model},
      kernel: KernelRegistry.claudeCode.id,
    ),
    null => null,
  };

  /// Claude Code's own tools of the web every bot has: searching it,
  /// reading a page.
  static const webTools = ['WebSearch', 'WebFetch'];

  // --- What a bot is offered -------------------------------------------------

  @override
  bool offersTool(String cwd, String tool) {
    final bot = botAt(cwd);
    final ability = BotTools.abilityOf(tool);
    if (bot == null) return ability == null;
    if (ability != null) return ability.allows(bot);
    // The app's other tools: pictures made, if it may make them; the
    // browser's, if it may use it.
    if (tool == ImageTools.name) return bot.can(BotAbility.images);
    return bot.can(BotAbility.browser) &&
        ClaudeSdkTools.called('mcp__${ClaudeSdkTools.server}__$tool')?.kind ==
            ToolKind.browser;
  }

  /// Not a bot's: there is no one at the computer to ask, its user on the
  /// phone.
  @override
  bool asksUser(String cwd) => botAt(cwd) == null;

  @override
  bool tellsFeature(String cwd, String feature) => switch (botAt(cwd)) {
    null => true,
    final bot => feature == 'browser' && bot.can(BotAbility.browser),
  };

  // --- Its conversation --------------------------------------------------

  /// [bot]'s conversation, if it has one.
  AgentThread? threadOf(Bot bot) {
    AgentThread? latest;
    for (final thread in workspace.threads) {
      if (thread.project.path != bot.folder || thread.archived) continue;
      if (latest == null || thread.updatedAt.isAfter(latest.updatedAt)) {
        latest = thread;
      }
    }
    return latest;
  }

  /// [bot]'s conversation, started if it has none.
  AgentThread threadFor(Bot bot) {
    if (threadOf(bot) case final thread?) return thread;
    folders.make(bot.folder);
    return workspace.startAgent(workspace.projectAt(bot.folder));
  }

  /// Has [bot]'s agent start again on its conversation, to be told what
  /// changed (its identity, abilities, memory) from its next message.
  void _restart(Bot bot) {
    final thread = threadOf(bot);
    if (thread == null || !thread.isOpen) return;
    final session = thread.session;
    if (session.isStreaming) {
      // Once it is done answering.
      _restartWhenIdle.add(bot.id);
    } else if (session.sessionId != null) {
      session.restart();
    }
  }

  /// How many messages [bot] sent since the user last read it: each of
  /// its messages, stickers, cards and pictures, as a chat app counts.
  int unread(Bot bot) {
    final thread = threadOf(bot);
    if (thread == null || !thread.isOpen) return 0;
    final session = thread.session;
    final count = session.itemCount;
    final seen = (_seen[bot.id] ??= count).clamp(0, count);
    final quiet = ChatCodec.botQuiet(count, session.itemAt);
    var unread = 0;
    for (var i = seen; i < count; i++) {
      if (_shown(session.itemAt(i), quiet.contains(i))) unread++;
    }
    return unread;
  }

  /// The user has read all [bot] said.
  void seen(Bot bot) {
    final thread = threadOf(bot);
    if (thread == null || !thread.isOpen) return;
    _seen[bot.id] = thread.session.itemCount;
    notifyListeners();
  }

  /// Whether [item] shows in a bot's chat as one of its messages: what it
  /// sent; a text of its own, unless [quiet] (see [ChatCodec.botQuiet]).
  static bool _shown(ChatItem item, bool quiet) => switch (item) {
    AssistantTextItem(:final text) => !quiet && text.trim().isNotEmpty,
    _ => ChatCodec.botSent(item),
  };

  /// Whether [bot] is writing to the user: at work, not on a note to
  /// itself at the end of a turn it talked in (see [ChatCodec.botQuiet]).
  bool typing(Bot bot) {
    final thread = threadOf(bot);
    if (thread == null || thread.status != ThreadStatus.running) return false;
    if (!thread.isOpen) return true;
    final session = thread.session;
    final last = session.itemCount - 1;
    return last < 0 ||
        session.itemAt(last) is! AssistantTextItem ||
        !ChatCodec.botQuiet(session.itemCount, session.itemAt).contains(last);
  }

  /// The last [bot] said: its first line; a picture or a sticker, as a
  /// chat app's list says it.
  String? lastLine(Bot bot) {
    final thread = threadOf(bot);
    if (thread == null || !thread.isOpen) return null;
    final session = thread.session;
    final quiet = ChatCodec.botQuiet(session.itemCount, session.itemAt);
    String? firstLine(String text) {
      final line = text
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty, orElse: () => '');
      if (line.isEmpty) return null;
      return line.length > 120 ? '${line.substring(0, 120)}…' : line;
    }

    for (var i = session.itemCount - 1; i >= 0; i--) {
      switch (session.itemAt(i)) {
        case AssistantTextItem(:final text) when !quiet.contains(i):
          if (firstLine(text) case final line?) return line;
        case final ToolCallItem item when ChatCodec.botSay(item) != null:
          if (firstLine(ChatCodec.botSay(item)!) case final line?) return line;
        case final ToolCallItem item when ChatCodec.botSticker(item) != null:
          final sticker = builtInSticker(ChatCodec.botSticker(item)!);
          final said = sticker == null
              ? ''
              : ' ${chinese ? sticker.zh : sticker.en}';
          return '${chinese ? '[表情]' : '[Sticker]'}$said';
        case final ToolCallItem item
            when item.status != ToolStatus.failed &&
                (item.images.isNotEmpty || ChatCodec.botImageUrl(item) != null):
          return chinese ? '[图片]' : '[Picture]';
        default:
      }
    }
    return null;
  }

  // --- Made, changed, deleted -----------------------------------------------

  /// [id]'s bot changed as given, or a new one (no [id]).
  Bot save({
    String? id,
    required String name,
    String? avatar,
    String gender = '',
    String signature = '',
    required String identity,
    String style = '',
    required Set<BotAbility> abilities,
    BotProactive proactive = const BotProactive(),
    BotAvatarImage? avatarImage,
    Bot? by,
  }) {
    final root = folders.root;
    if (root == null) throw StateError('No bots here');
    name = name.trim();
    if (name.isEmpty) throw ArgumentError('A bot needs a name');
    final Bot bot;
    if (id == null) {
      final newId = _newId();
      bot = Bot(
        id: newId,
        name: name,
        folder: '',
        avatar: _avatar(p.join(root, newId), avatar, avatarImage),
        gender: gender.trim(),
        signature: signature.trim(),
        identity: identity.trim(),
        style: style.trim(),
        abilities: abilities,
        proactive: proactive,
        created: _clock(),
      );
      final made = Bot.fromJson(bot.toJson(), root: root)!;
      folders.make(made.folder);
      _bots.add(made);
      if (_started) threadFor(made);
      _save();
      notifyListeners();
      return made;
    }
    final index = _bots.indexWhere((b) => b.id == id);
    if (index < 0) throw StateError('No bot $id');
    final had = _bots[index];
    final picked = _avatar(had.folder, avatar, avatarImage, had: had.avatar);
    if (had.avatarFile case final file? when picked != had.avatar) {
      folders.deleteFile(file);
    }
    bot = _bots[index] = had.copyWith(
      name: name,
      avatar: picked,
      clearAvatar: picked == null,
      gender: gender.trim(),
      signature: signature.trim(),
      identity: identity.trim(),
      style: style.trim(),
      abilities: abilities,
      proactive: proactive,
    );
    if (!bot.can(BotAbility.viewChats)) _pacers.remove(bot.id);
    _save();
    _restart(bot);
    // Changed by itself, it knows.
    if (by?.id != bot.id) _tellChanged(had, bot, avatarImage, by: by);
    notifyListeners();
    return bot;
  }

  /// Tells [bot] what the user (or the bot [by]) changed of it ([had]
  /// before): who it is now, its new picture with it to see. Its to react
  /// to, or not.
  void _tellChanged(Bot had, Bot bot, BotAvatarImage? picture, {Bot? by}) {
    String quoted(String text) => text.isEmpty ? '(none)' : '"$text"';
    final lines = [
      if (had.name != bot.name) '- Your name: now ${quoted(bot.name)}.',
      if (picture != null)
        '- Your picture: a new one chosen for you, here. Look at '
            'it, and keep in a line what it shows (bot_remember, about '
            'self).'
      else if (had.avatar != bot.avatar)
        switch (bot.avatar) {
          null => "- Your picture: none now, your name's first letter.",
          final emoji => '- Your picture: now the emoji $emoji.',
        },
      if (had.gender != bot.gender) '- Your gender: now ${quoted(bot.gender)}.',
      if (had.signature != bot.signature)
        '- The line under your name: now ${quoted(bot.signature)}.',
      if (had.identity != bot.identity)
        '- Who you are, in their words, now:\n${bot.identity}',
      if (had.style != bot.style)
        '- How you talk, in their words, now:\n${bot.style}',
      for (final ability in BotAbility.values)
        if (bot.can(ability) != had.can(ability))
          '- ${bot.can(ability) ? 'You may now' : 'You may no longer'}: '
              '${ability.name}.',
    ];
    if (lines.isEmpty) return;
    final thread = threadOf(bot);
    if (thread == null || !thread.isOpen) return;
    thread.session.send(
      ComposerMessage(
        text: botEventMessage(
          [
            by == null
                ? 'The user changed your profile:'
                : '${by.name} (${by.assistant ? 'the assistant, who looks after '
                                "the user's bots" : 'another bot'}) changed your '
                      'profile:',
            ...lines,
            'Now: ${botTime(_clock())}.',
          ].join('\n'),
        ),
        images: [
          if (picture != null)
            ImageAttachment(bytes: picture.bytes, mediaType: picture.type),
        ],
      ),
    );
  }

  /// What [bot] keeps of itself: what it said it likes, has done, thinks;
  /// to be the same one each time. Empty for nothing.
  String selfNotes(Bot bot) {
    final bytes = folders.readFile(p.join(bot.folder, selfFile));
    return bytes == null ? '' : utf8.decode(bytes, allowMalformed: true);
  }

  /// [bot]'s notes of itself now [text]: by itself, as it goes; else the
  /// user's, which it is told from its next message ([restart]).
  void setSelfNotes(Bot bot, String text, {bool restart = false}) {
    folders.writeFile(
      p.join(bot.folder, selfFile),
      Uint8List.fromList(utf8.encode(text.trim().isEmpty ? '' : text)),
    );
    if (!restart) return;
    _restart(bot);
    notifyListeners();
  }

  /// The file in its folder [selfNotes] are kept in.
  static const selfFile = 'SELF.md';

  /// The avatar a bot in [folder] is saved with: [image], kept there as
  /// a file named after what it shows; else [asked], an emoji, or the
  /// picture it [had].
  String? _avatar(
    String folder,
    String? asked,
    BotAvatarImage? image, {
    String? had,
  }) {
    if (image != null) {
      final hash = sha1.convert(image.bytes).toString().substring(0, 12);
      final name = 'avatar-$hash${_extensions[image.type] ?? '.png'}';
      folders.writeFile(p.join(folder, name), image.bytes);
      return name;
    }
    final avatar = asked?.trim();
    if (avatar == null || avatar.isEmpty) return null;
    // A picture only by the name of the one it has.
    if (isAvatarImage(avatar)) return avatar == had ? avatar : null;
    return avatar;
  }

  static const _extensions = {
    'image/png': '.png',
    'image/jpeg': '.jpg',
    'image/webp': '.webp',
    'image/gif': '.gif',
  };

  /// [bot]'s picture, if it has one there.
  BotAvatarImage? avatarImage(Bot bot) {
    final file = bot.avatarFile;
    if (file == null) return null;
    final bytes = folders.readFile(file);
    if (bytes == null) return null;
    return (bytes: bytes, type: _typeOf(file));
  }

  static String _typeOf(String file) =>
      switch (p.extension(file).toLowerCase()) {
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        _ => 'image/png',
      };

  String _newId() {
    final now = _clock().microsecondsSinceEpoch.toRadixString(36);
    var id = 'b$now';
    for (var n = 2; byId(id) != null; n++) {
      id = 'b$now-$n';
    }
    return id;
  }

  /// Deletes [id]'s bot, its conversation and memory: not the assistant's.
  void delete(String id) {
    final bot = byId(id);
    if (bot == null) return;
    if (bot.assistant) throw StateError('The assistant stays');
    workspace.deleteAll([
      for (final thread in workspace.threads)
        if (thread.project.path == bot.folder) thread,
    ]);
    folders.delete(bot.folder);
    _bots.remove(bot);
    _pacers.remove(id);
    _laters.remove(id);
    _watching.remove(id);
    _seen.remove(id);
    _save();
    notifyListeners();
  }

  /// [bot] runs on [model] from now on: picked on its conversation, for
  /// the next it starts to run on it too.
  void setModel(Bot bot, String model) {
    final index = _bots.indexWhere((b) => b.id == bot.id);
    if (index < 0 || _bots[index].model == model) return;
    _bots[index] = _bots[index].copyWith(model: model);
    _save();
    notifyListeners();
  }

  /// The model [bot]'s conversation runs on, as the picker names it.
  String? modelOf(Bot bot) {
    final thread = threadOf(bot);
    if (thread != null && thread.isOpen) {
      if (thread.session.models?.selected case final model?) {
        return model.label;
      }
    }
    return bot.model;
  }

  String memory(Bot bot) => folders.readMemory(bot.folder);

  // --- The user ---------------------------------------------------------

  /// Who the user is, as they put it on their phone: for the bots to know.
  BotUser get me => _me;

  /// The user's own picture, as their phone sent it; none for none.
  BotAvatarImage? get myPicture {
    final root = folders.root;
    final file = _me.picture;
    if (root == null || file == null) return null;
    final bytes = folders.readFile(p.join(root, file));
    return bytes == null ? null : (bytes: bytes, type: _typeOf(file));
  }

  /// Who the user is now [me], their picture [picture] (none for none):
  /// told the bots from their next message, if it changed.
  void setMe(BotUser me, BotAvatarImage? picture) {
    final root = folders.root;
    if (root == null) return;
    String? file;
    if (picture != null) {
      final hash = sha1.convert(picture.bytes).toString().substring(0, 12);
      file = 'me-$hash${_extensions[picture.type] ?? '.png'}';
      if (file != _me.picture) {
        folders.writeFile(p.join(root, file), picture.bytes);
      }
    }
    final now = me.withPicture(file);
    if (now == _me) return;
    if (_me.picture case final old? when old != file) {
      folders.deleteFile(p.join(root, old));
    }
    _me = now;
    _save();
    _bots.forEach(_restart);
    notifyListeners();
  }

  void setMemory(Bot bot, String text) {
    folders.writeMemory(bot.folder, text.trim().isEmpty ? '' : text);
    _restart(bot);
    notifyListeners();
  }

  // --- Writing first ------------------------------------------------------

  /// What changed for the agents the sidebar lists, told the bots that
  /// write first.
  void _watch() {
    _follow();
    final gone = {..._statuses.keys};
    final events = <BotEvent>[];
    for (final thread in workspace.threads) {
      if (thread.archived || isBotThread(thread)) continue;
      if (!workspace.listsInSidebar(thread)) continue;
      gone.remove(thread);
      final now = thread.status;
      final was = _statuses[thread];
      _statuses[thread] = now;
      if (now == ThreadStatus.running) {
        _runningSince[thread] ??= _clock();
      } else {
        _runningSince.remove(thread);
        _toldRunning.remove(thread);
      }
      if (was == null || was == now) continue;
      final kind = switch ((was, now)) {
        (_, ThreadStatus.needsInput) => BotEventKind.waiting,
        (ThreadStatus.running, ThreadStatus.idle || ThreadStatus.unread)
            when _failed(thread) =>
          BotEventKind.failed,
        (ThreadStatus.running, ThreadStatus.idle || ThreadStatus.unread) =>
          BotEventKind.done,
        _ => null,
      };
      if (kind == null) continue;
      events.add(
        _event(
          thread,
          kind,
          detail: kind == BotEventKind.failed ? _error(thread) : null,
        ),
      );
    }
    for (final thread in gone) {
      _statuses.remove(thread);
      _runningSince.remove(thread);
      _toldRunning.remove(thread);
    }
    _tell(events);
    _checkRunning();
  }

  BotEvent _event(AgentThread thread, BotEventKind kind, {String? detail}) =>
      BotEvent(
        chat: BotTools.idOf(thread),
        title: thread.title,
        project: thread.project.name,
        kind: kind,
        at: _clock(),
        detail: detail,
      );

  /// Follows each bot's conversation open: tells, as it changes, when a
  /// message comes or it starts or stops writing ([typing]).
  void _follow() {
    for (final bot in _bots) {
      final thread = threadOf(bot);
      if (thread == null || !thread.isOpen) continue;
      final session = thread.session;
      if (_followed.containsKey(session)) continue;
      Object? was;
      void listener() {
        if (!session.isStreaming && _restartWhenIdle.remove(bot.id)) {
          _restart(bot);
        }
        final last = session.itemCount - 1;
        final now = (
          session.itemCount,
          session.isStreaming,
          last >= 0 && session.itemAt(last) is AssistantTextItem,
        );
        if (now == was) return;
        was = now;
        notifyListeners();
      }

      _followed[session] = listener;
      session.addListener(listener);
    }
  }

  /// [events] for the bots they concern, to tell when it is time: the
  /// assistant, which looks after the agents, of all of them (if it may
  /// see them); another, of those it started or wrote to. Not every bot
  /// of everything, each to write of it.
  void _tell(List<BotEvent> events) {
    if (events.isEmpty) return;
    for (final bot in _bots) {
      final watching = _watching[bot.id] ?? const <String>[];
      final told = [
        for (final event in events)
          if (bot.assistant
              ? bot.can(BotAbility.viewChats)
              : watching.contains(event.chat))
            event,
      ];
      if (told.isEmpty) continue;
      final pacer = _pacers[bot.id] ??= BotPacer();
      told.forEach(pacer.add);
    }
    _schedule();
  }

  /// [bot] started [thread], or wrote to it: told what becomes of it.
  void watch(Bot bot, AgentThread thread) {
    final id = BotTools.idOf(thread);
    final watching = _watching[bot.id] ??= [];
    watching
      ..remove(id)
      ..add(id);
    if (watching.length > maxWatching) {
      watching.removeRange(0, watching.length - maxWatching);
    }
    _save();
  }

  /// The agents [bot] is told of for having started or written to them.
  List<String> watching(Bot bot) => List.unmodifiable(_watching[bot.id] ?? []);

  /// The agents at work for [longRun] and more, told of once a run; and
  /// a look again when the next of them will be.
  @visibleForTesting
  void checkRunning() => _checkRunning();

  void _checkRunning() {
    _runningTimer?.cancel();
    _runningTimer = null;
    final now = _clock();
    final events = <BotEvent>[];
    DateTime? next;
    for (final MapEntry(key: thread, value: since) in _runningSince.entries) {
      if (_toldRunning.contains(thread)) continue;
      final due = since.add(longRun);
      if (!due.isAfter(now)) {
        _toldRunning.add(thread);
        events.add(
          _event(
            thread,
            BotEventKind.running,
            detail:
                'running for ${(now.difference(since).inSeconds / 60).round()} min',
          ),
        );
      } else if (next == null || due.isBefore(next)) {
        next = due;
      }
    }
    _tell(events);
    if (next != null) {
      _runningTimer = Timer(next.difference(now), _checkRunning);
    }
  }

  bool isBotThread(AgentThread thread) => botAt(thread.project.path) != null;

  static bool _failed(AgentThread thread) => _error(thread) != null;

  static String? _error(AgentThread thread) {
    if (!thread.isOpen) return null;
    final session = thread.session;
    for (var i = session.itemCount - 1; i >= 0; i--) {
      switch (session.itemAt(i)) {
        case NoticeItem(kind: NoticeKind.error, :final text):
          return text.split('\n').first;
        case UserMessageItem() || AssistantTextItem():
          return null;
        default:
      }
    }
    return null;
  }

  /// [bot] comes back, on its own, to [note] [after] from now: when.
  DateTime later(Bot bot, Duration after, String note) {
    final at = _clock().add(after);
    final laters = _laters[bot.id] ??= [];
    laters
      ..add(BotLater(at: at, note: note.trim()))
      ..sort((a, b) => a.at.compareTo(b.at));
    // The latest dropped, past the most it may have.
    if (laters.length > maxLaters) laters.removeRange(maxLaters, laters.length);
    _save();
    _schedule();
    return at;
  }

  /// What [bot] meant to come back to, soonest first.
  List<BotLater> laters(Bot bot) => List.unmodifiable(_laters[bot.id] ?? []);

  /// [bot] no longer comes back to what its notes say [which] of (a part
  /// of one, any case): those it dropped.
  List<BotLater> cancelLaters(Bot bot, String which) {
    final part = which.trim().toLowerCase();
    final laters = _laters[bot.id];
    if (part.isEmpty || laters == null) return const [];
    final dropped = [
      for (final later in laters)
        if (later.note.toLowerCase().contains(part)) later,
    ];
    if (dropped.isEmpty) return const [];
    laters.removeWhere(dropped.contains);
    _save();
    _schedule();
    return dropped;
  }

  void _schedule() {
    _timer?.cancel();
    final now = _clock();
    DateTime? next;
    for (final bot in _bots) {
      var due = _pacers[bot.id]?.dueAt(now);
      if (_laters[bot.id]?.firstOrNull case final later?) {
        final at = later.at.isBefore(now) ? now : later.at;
        if (due == null || at.isBefore(due)) due = at;
      }
      if (due != null && (next == null || due.isBefore(next))) next = due;
    }
    if (next == null) return;
    _timer = Timer(next.difference(now), deliver);
  }

  /// Tells each bot what is due: a message of the app's in its
  /// conversation, which it answers as it writes first.
  @visibleForTesting
  void deliver() {
    final now = _clock();
    var busy = false;
    for (final bot in _bots) {
      final pacer = _pacers[bot.id];
      final waiting = _laters[bot.id] ?? const <BotLater>[];
      if (pacer == null && waiting.isEmpty) continue;
      final thread = threadFor(bot);
      // Not while it is answering: after.
      if (thread.isOpen && thread.session.isStreaming) {
        busy = true;
        continue;
      }
      final events = pacer?.take(now) ?? const <BotEvent>[];
      final due = [
        for (final later in waiting)
          if (!later.at.isAfter(now)) later,
      ];
      if (events.isEmpty && due.isEmpty) continue;
      if (due.isNotEmpty) {
        waiting.removeWhere(due.contains);
        _save();
      }
      thread.session.send(
        ComposerMessage(
          text: botEventMessage(botWakeText(now, events: events, laters: due)),
        ),
      );
    }
    if (busy || _pacers.values.any((p) => p.hasPending)) {
      _timer?.cancel();
      _timer = Timer(const Duration(seconds: 30), _schedule);
    } else {
      _schedule();
    }
  }
}
