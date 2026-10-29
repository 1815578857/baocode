import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_pacer.dart';
import 'package:baocode/bots/bot_permissions.dart';
import 'package:baocode/bots/bot_prompt.dart';
import 'package:baocode/bots/bot_tools.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/queued_messages.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/claude_code/mock_claude_code_transport.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/images/image_tools.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('BotPacer', () {
    final start = DateTime(2026, 10, 29, 14);
    BotEvent event(String chat, BotEventKind kind, DateTime at) => BotEvent(
      chat: chat,
      title: 'Agent $chat',
      project: 'monad',
      kind: kind,
      at: at,
    );

    test('what comes close together is told at once, what needs the user '
        'first', () {
      final pacer = BotPacer();
      pacer
        ..add(event('a', BotEventKind.done, start))
        ..add(event('b', BotEventKind.failed, start.add(seconds(20))))
        ..add(event('c', BotEventKind.waiting, start.add(seconds(40))));
      expect(pacer.take(start.add(seconds(60))), isNull);
      final told = pacer.take(start.add(seconds(90)))!;
      expect(told.map((e) => e.chat), ['c', 'b', 'a']);
      expect(pacer.hasPending, isFalse);
    });

    test('an agent\'s latest only', () {
      final pacer = BotPacer()
        ..add(event('a', BotEventKind.waiting, start))
        ..add(event('a', BotEventKind.done, start.add(seconds(10))));
      final told = pacer.take(start.add(const Duration(minutes: 5)))!;
      expect(told.single.kind, BotEventKind.done);
    });

    test('told as soon as gathered, whatever the hour: the bot judges', () {
      final night = DateTime(2026, 10, 29, 23, 30);
      final pacer = BotPacer()..add(event('a', BotEventKind.failed, night));
      expect(pacer.dueAt(night), night.add(seconds(90)));
      expect(pacer.take(night.add(seconds(90))), isNotNull);
      // And again at once, of what came since.
      final later = night.add(minutes(2));
      pacer.add(event('b', BotEventKind.failed, later));
      expect(pacer.take(later.add(seconds(90))), isNotNull);
    });

    test('what was done long ago is not worth telling', () {
      final pacer = BotPacer()
        ..add(event('a', BotEventKind.done, start))
        ..add(event('b', BotEventKind.waiting, start));
      final told = pacer.take(start.add(const Duration(hours: 7)))!;
      expect(told.map((e) => e.chat), ['b']);
    });
  });

  group('what a bot is told', () {
    const bot = Bot(
      id: 'b',
      name: 'Mia',
      folder: '/bots/b',
      gender: 'female',
      signature: 'Tea first.',
      identity: 'An old friend, playful and kind.',
      style: 'Lowercase, lots of emoji.',
      abilities: {BotAbility.viewChats},
    );

    test('the rules first, then who the user made it', () {
      final told = botInstructions(bot, memory: 'Likes tea.');
      expect(told.indexOf('<bot_rules>'), 0);
      expect(told, contains('say you are an AI'));
      expect(told, contains('No sexual or explicit content'));
      expect(told, contains('12356'));
      expect(told, contains('cannot approve or deny'));
      expect(
        told.indexOf('<bot_rules>'),
        lessThan(told.indexOf('An old friend')),
      );
      expect(told, contains('Your name is Mia.'));
      expect(told, contains('Your gender, as the user put it: female.'));
      expect(told, contains('Tea first.'));
      expect(told, contains('How you talk, in the user\'s words:'));
      expect(told, contains('Lowercase, lots of emoji.'));
      expect(told, contains('Likes tea.'));
    });

    test('all it is: its picture, when and where, what runs it', () {
      final made = DateTime(2026, 10, 1, 9);
      final told = botInstructions(
        Bot(
          id: 'b',
          name: 'Mia',
          folder: '/bots/b',
          avatar: '🌸',
          created: made,
        ),
        memory: '',
        self: '- Grew up by the sea',
        computer: 'Leo 的 MacBook',
        model: 'Opus 5.5',
      );
      expect(
        told,
        contains(
          'Your picture (what the user sees beside your '
          'messages): the emoji 🌸.',
        ),
      );
      expect(told, contains('The user made you on Thursday 2026-10-01.'));
      expect(told, contains('("Leo 的 MacBook")'));
      expect(told, contains('the model Opus 5.5'));
      // A person of its own, the same each time.
      expect(told, contains('<personality>'));
      expect(told, contains('Grew up by the sea'));
      // A picture of the user's choosing: looked at, if not noted.
      final pictured = botIdentity(
        const Bot(id: 'b', name: 'Mia', folder: '/b', avatar: 'avatar-1.png'),
      );
      expect(pictured, contains('bot_my_picture'));
      expect(
        botIdentity(const Bot(id: 'b', name: 'Mia', folder: '/b')),
        contains("your name's first letter"),
      );
    });

    test('when a bot was made, from its id if not kept', () {
      final at = DateTime(2026, 10, 29, 14);
      final id = 'b${at.microsecondsSinceEpoch.toRadixString(36)}';
      expect(Bot.fromJson({'id': id, 'name': 'x'}, root: '/b')!.created, at);
      expect(
        Bot.fromJson({'id': 'assistant', 'name': 'x'}, root: '/b')!.created,
        isNull,
      );
    });

    test('what it may do, and may not', () {
      final told = botAbilities(bot);
      expect(told, contains('bot_list_chats'));
      expect(told, contains('You cannot stop, retry or archive agents.'));
      expect(told, contains('You cannot use the browser.'));
      expect(told, contains('You cannot make pictures.'));
    });

    test('what of Claude Code\'s it has, by what it may', () {
      Bot bot(Set<BotAbility> abilities) =>
          Bot(id: 'b1', name: 'Mia', folder: '/bots/b1', abilities: abilities);
      // Only the web's.
      final none = bot({});
      expect(BotPermissions.tools(none), ['WebSearch', 'WebFetch']);
      expect(BotPermissions.reaches(none, projects: ['/p']), isEmpty);
      // Working on the computer: its hands, the projects its folders.
      final hands = bot({BotAbility.readFiles});
      expect(BotPermissions.tools(hands), [
        'WebSearch',
        'WebFetch',
        'Read',
        'Write',
        'Edit',
        'Bash',
      ]);
      expect(BotPermissions.reaches(hands, projects: ['/p']), ['/p']);
      // The browser's, by the tool search.
      expect(BotPermissions.tools(bot({BotAbility.browser})), [
        'WebSearch',
        'WebFetch',
        'ToolSearch',
      ]);
    });

    test('one kept working on the computer works on the files now', () {
      final kept = Bot.fromJson({
        'id': 'b1',
        'name': 'Mia',
        'abilities': ['computer', 'viewChats'],
      }, root: '/b')!;
      expect(kept.abilities, {BotAbility.readFiles, BotAbility.viewChats});
    });

    test('pictures: made with the image model, or said there is none', () {
      final painter = Bot(
        id: 'p',
        name: 'Pia',
        folder: '/bots/p',
        abilities: {BotAbility.images},
      );
      expect(botAbilities(painter), contains('generate_image'));
      expect(
        botAbilities(painter, imageModel: false),
        contains('no image model turned on'),
      );
      // Emoji, not the app's stickers; pictures of its own.
      expect(botChatStyle, contains('emoji'));
      expect(botChatStyle, isNot(contains('bot_send_sticker')));
      expect(botChatStyle, contains('bot_send_image'));
    });
  });

  group('Bots', () {
    final launches = <ClaudeLaunch>[];
    late KernelDescriptor kernel;
    kernel = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      create: (context) => ClaudeCodeKernel(
        kernel,
        context,
        start: (launch) {
          launches.add(launch);
          return MockClaudeCodeTransport.start(launch);
        },
      ),
    );
    late Workspace workspace;
    late Bots bots;
    late MemoryBotFolders folders;
    late MemoryPreferenceStore store;
    late DateTime now;
    late String app;

    setUp(() async {
      launches.clear();
      app = Directory.systemTemp.createTempSync('bots-app').path;
      addTearDown(() => Directory(app).deleteSync(recursive: true));
      workspace = Workspace(kernels: [kernel], projects: [Project('app', app)]);
      folders = MemoryBotFolders();
      store = MemoryPreferenceStore();
      now = DateTime(2026, 10, 29, 14);
      bots = Bots(
        workspace: workspace,
        folders: folders,
        store: store,
        chinese: true,
        clock: () => now,
        computer: () async => 'Leo 的 MacBook',
      );
      await bots.start();
    });

    tearDown(() {
      bots.dispose();
      workspace.dispose();
    });

    Future<List<String>> offered(String cwd) async {
      final answer = await ClaudeSdkTools.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      }, ClaudeSdkCall(cwd: cwd));
      return [
        for (final tool
            in ((answer['result'] as Map)['tools'] as List).cast<Map>())
          tool['name'] as String,
      ];
    }

    test('start with the assistant, every ability on, kept', () async {
      final assistant = bots.bots.single;
      expect(assistant.assistant, isTrue);
      expect(assistant.name, '小宝');
      expect(assistant.abilities, BotAbility.values.toSet());
      expect(folders.folders, contains(assistant.folder));
      await pumpEventQueue();
      expect(
        (store.preferences['bots'] as List).single,
        containsPair('id', 'assistant'),
      );
    });

    test('a bot\'s folder is no project of the sidebar\'s', () {
      final bot = bots.bots.single;
      final thread = bots.threadFor(bot);
      expect(workspace.isHidden(thread.project), isTrue);
      expect(workspace.listsInSidebar(thread), isFalse);
      expect(bots.threadFor(bot), same(thread));
      expect(workspace.agentSetup!(bot.folder)!.settings, Bots.settings);
      // Named by none of what it is told.
      thread.session.send(const ComposerMessage(text: '<bao-event>x'));
      workspace.notifyListeners();
      expect(thread.title, isNot(contains('bao-event')));
      expect(workspace.agentSetup!(app), isNull);
    });

    test('its agent is told who it is, with its own tools only', () async {
      final bot = bots.bots.single;
      bots.threadFor(bot).session.send(const ComposerMessage(text: '在吗'));
      for (var i = 0; i < 50 && launches.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final launch = launches.single;
      expect(launch.cwd, bot.folder);
      expect(launch.instructions, contains('<bot_rules>'));
      expect(launch.instructions, contains('小宝'));
      // Its prompt in place of a coding agent's: none of the chat's notes
      // on citing code either.
      expect(launch.ownPrompt, isTrue);
      expect(launch.arguments, contains('--system-prompt'));
      expect(launch.arguments, isNot(contains('--append-system-prompt')));
      expect(launch.arguments.join(' '), isNot(contains('<citing_code>')));
      // What the user writes meanwhile, taken up as it talks.
      expect(
        workspace.agentSetup!(bot.folder)!.workspace().queuedMessages,
        QueuedMessages.duringTurn,
      );
      // Full access, nothing asked: the CLI accepting edits, the rest
      // approved by the kernel, what the CLI would ask about too.
      expect(launch.permissionMode, 'acceptEdits');
      expect(
        workspace.agentSetup!(bot.folder)!.workspace().approvesAll,
        isTrue,
      );
      expect(launch.sdkServers, [ClaudeSdkTools.server]);
      // The web's; the projects worked in, as it may (the assistant may
      // all); the browser's tool search; no other.
      expect(launch.tools, [
        'WebSearch',
        'WebFetch',
        'Read',
        'Write',
        'Edit',
        'Bash',
        'ToolSearch',
      ]);
      expect(
        launch.arguments,
        containsAllInOrder([
          '--tools',
          'WebSearch,WebFetch,Read,Write,Edit,Bash,ToolSearch',
        ]),
      );
      // Nothing it is made to ask about.
      expect(
        (launch.settings['permissions'] as Map?)?.containsKey('ask'),
        isNot(true),
      );
      expect(launch.instructions, contains('- app: $app'));
      // The projects its working directories, their CLAUDE.md not read.
      expect(launch.directories, [app]);
      expect(
        (launch.settings['env'] as Map).containsKey(
          'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD',
        ),
        isFalse,
      );
      // None of the user's MCP servers: their notices are not its to tell.
      expect(launch.arguments, contains('--strict-mcp-config'));
    });

    test(
      'a bot is offered its abilities\' tools; a project\'s agent none',
      () async {
        final assistant = bots.bots.single;
        expect(
          await offered(assistant.folder),
          containsAll(['bot_list_chats', 'bot_stop_chat', 'bot_remember']),
        );
        expect(await offered(app), isNot(contains('bot_list_chats')));
        expect(ClaudeSdkTools.serversFor(app), isEmpty);

        // A new one may do nothing until the user says.
        final mia = bots.save(
          name: 'Mia',
          identity: '',
          abilities: {BotAbility.viewChats},
        );
        final hers = await offered(mia.folder);
        expect(hers, containsAll(['bot_list_chats', 'bot_show_chat']));
        expect(hers, isNot(contains('bot_stop_chat')));
        expect(hers, isNot(contains('bot_read_file')));
        final none = bots.save(name: 'Quiet', identity: '', abilities: {});
        expect(await offered(none.folder), [
          'bot_say',
          'bot_later',
          'bot_cancel_later',
          'bot_send_image',
          'bot_remember',
          'bot_my_picture',
          'bot_user_picture',
        ]);
        // The assistant's alone: its contacts looked after.
        expect(
          await offered(assistant.folder),
          containsAll(['bot_list_bots', 'bot_save_bot', 'bot_delete_bot']),
        );
        // Nor called, though named.
        final refused = await ClaudeSdkTools.handle({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': {
            'name': 'bot_list_chats',
            'arguments': <String, Object?>{},
          },
        }, ClaudeSdkCall(cwd: none.folder));
        expect((refused['result'] as Map)['isError'], isTrue);
      },
    );

    test('bots are changed and deleted; the assistant stays', () {
      final mia = bots.save(name: ' Mia ', identity: 'x', abilities: {});
      expect(mia.name, 'Mia');
      final changed = bots.save(
        id: mia.id,
        name: 'Mia',
        avatar: '🌸',
        identity: 'y',
        abilities: {BotAbility.proactive},
        proactive: const BotProactive(perDay: 0),
      );
      expect(changed.avatar, '🌸');
      expect(bots.byId(mia.id)!.proactive.perDay, 0);
      bots.delete(mia.id);
      expect(bots.byId(mia.id), isNull);
      expect(folders.folders, isNot(contains(mia.folder)));
      expect(() => bots.delete('assistant'), throwsStateError);
      expect(
        () => bots.save(name: ' ', identity: '', abilities: {}),
        throwsArgumentError,
      );
    });

    test('who it is, all the user wrote, kept; its model too', () async {
      final mia = bots.save(
        name: 'Mia',
        gender: ' female ',
        signature: 'Tea first.',
        identity: 'An old friend.',
        style: 'Short.',
        abilities: {},
      );
      expect(
        (mia.gender, mia.signature, mia.style),
        ('female', 'Tea first.', 'Short.'),
      );
      bots.setModel(mia, 'opus');
      expect(workspace.agentSetup!(mia.folder)!.settings, {
        ...Bots.settings,
        'model': 'opus',
      });
      await pumpEventQueue();
      final kept = Bot.fromJson(
        (store.preferences['bots'] as List).last,
        root: folders.root!,
      )!;
      expect(
        (kept.gender, kept.signature, kept.style, kept.model),
        ('female', 'Tea first.', 'Short.', 'opus'),
      );
    });

    test('its picture: kept in its folder, named by what it shows', () {
      final png = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
      final mia = bots.save(
        name: 'Mia',
        identity: '',
        abilities: {},
        avatarImage: (bytes: png, type: 'image/png'),
      );
      expect(mia.avatar, matches(RegExp(r'^avatar-[0-9a-f]{12}\.png$')));
      expect(isAvatarImage(mia.avatar), isTrue);
      expect(folders.files[mia.avatarFile], png);
      expect(bots.avatarImage(mia), (bytes: png, type: 'image/png'));

      // Kept as it is, by its name; not another file by a name.
      final kept = bots.save(
        id: mia.id,
        name: 'Mia',
        avatar: mia.avatar,
        identity: 'x',
        abilities: {},
      );
      expect(kept.avatar, mia.avatar);
      expect(
        bots
            .save(
              id: mia.id,
              name: 'Mia',
              avatar: 'avatar-000000000000.png',
              identity: 'x',
              abilities: {},
            )
            .avatar,
        isNull,
      );
      // An emoji in its place: the file gone.
      final again = bots.save(
        id: mia.id,
        name: 'Mia',
        identity: '',
        abilities: {},
        avatarImage: (bytes: png, type: 'image/png'),
      );
      final emoji = bots.save(
        id: mia.id,
        name: 'Mia',
        avatar: '🌸',
        identity: '',
        abilities: {},
      );
      expect(emoji.avatar, '🌸');
      expect(folders.files, isNot(contains(again.avatarFile)));
      expect(bots.avatarImage(emoji), isNull);
    });

    test('the assistant has abilities that came since it was kept', () {
      final root = folders.root!;
      final assistant = Bot.fromJson({
        'id': 'assistant',
        'name': 'Bao',
        'assistant': true,
        'abilities': ['viewChats'],
      }, root: root)!;
      // Those the user had turned off stay off; the new ones are on.
      expect(assistant.can(BotAbility.images), isTrue);
      expect(assistant.can(BotAbility.browser), isFalse);
      // Not so for the user's own, as a new one has none.
      final mia = Bot.fromJson({
        'id': 'b1',
        'name': 'Mia',
        'abilities': ['viewChats'],
      }, root: root)!;
      expect(mia.can(BotAbility.images), isFalse);
      // Once kept with it, as the user left it.
      final off = Bot.fromJson(
        assistant.copyWith(abilities: {BotAbility.viewChats}).toJson(),
        root: root,
      )!;
      expect(off.abilities, {BotAbility.viewChats});
    });

    test('pictures are made by those that may, the model not asked', () async {
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: ImageTools.name,
          description: '',
          inputSchema: const {'type': 'object'},
          run: (input, call) async => '',
        ),
      );
      addTearDown(() => ClaudeSdkTools.unregister(ImageTools.name));
      final assistant = bots.bots.single;
      expect(await offered(assistant.folder), contains(ImageTools.name));
      final mia = bots.save(name: 'Mia', identity: '', abilities: {});
      expect(await offered(mia.folder), isNot(contains(ImageTools.name)));
      // No one at the computer to pick the model for it.
      expect(ClaudeSdkTools.asksUser(assistant.folder), isFalse);
      expect(ClaudeSdkTools.asksUser(app), isTrue);
    });

    test('it sends pictures from the web or a project', () async {
      Future<Map> call(
        Bot bot,
        String tool,
        Map<String, Object?> input,
      ) async =>
          (await ClaudeSdkTools.handle({
                'jsonrpc': '2.0',
                'id': 4,
                'method': 'tools/call',
                'params': {'name': tool, 'arguments': input},
              }, ClaudeSdkCall(cwd: bot.folder)))['result']
              as Map;
      final assistant = bots.bots.single;
      // No stickers of the app's now: emoji in its messages.
      expect(
        await offered(assistant.folder),
        isNot(contains('bot_send_sticker')),
      );
      expect(
        (await call(assistant, 'bot_send_image', {
          'url': 'https://example.com/cat.png',
        }))['isError'],
        isNot(isTrue),
      );
      expect(
        (await call(assistant, 'bot_send_image', {
          'url': 'file:///etc/x',
        }))['isError'],
        isTrue,
      );

      // A project's picture: back as the picture, for the chat.
      final png = base64.decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
        '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      );
      File('$app/pic.png').writeAsBytesSync(png);
      final sent = await call(assistant, 'bot_send_image', {
        'project': 'app',
        'path': 'pic.png',
      });
      expect(sent['isError'], isNot(isTrue));
      expect(
        (sent['content'] as List).map((c) => (c as Map)['type']),
        contains('image'),
      );
      expect(
        (await call(assistant, 'bot_send_image', {
          'project': 'app',
          'path': '../outside.png',
        }))['isError'],
        isTrue,
      );
      // Not by one that may not read the projects' files.
      final mia = bots.save(name: 'Mia', identity: '', abilities: {});
      expect(
        (await call(mia, 'bot_send_image', {
          'project': 'app',
          'path': 'pic.png',
        }))['isError'],
        isTrue,
      );
    });

    Future<Map> call(Bot bot, String tool, Map<String, Object?> input) async =>
        (await ClaudeSdkTools.handle({
              'jsonrpc': '2.0',
              'id': 5,
              'method': 'tools/call',
              'params': {'name': tool, 'arguments': input},
            }, ClaudeSdkCall(cwd: bot.folder)))['result']
            as Map;

    test('it talks with bot_say, a pause after each message', () async {
      final paused = <String>[];
      BotTools.pause = (text) {
        paused.add(text);
        return Duration.zero;
      };
      addTearDown(() => BotTools.pause = BotTools.typingPause);
      final bot = bots.bots.single;
      final sent = await call(bot, 'bot_say', {'text': '等下 我看看'});
      expect(sent['isError'], isNot(isTrue));
      // The time told, as the conversation goes on.
      expect('${sent['content']}', contains('Thursday 2026-10-29 14:00'));
      expect(paused, ['等下 我看看']);
      expect((await call(bot, 'bot_say', {'text': ' '}))['isError'], isTrue);
      // As long as it takes to write, about; never long.
      expect(BotTools.typingPause('嗯'), const Duration(milliseconds: 600));
      expect(
        BotTools.typingPause('x' * 500),
        const Duration(milliseconds: 2400),
      );
    });

    test('it comes back later on its own, when it said', () async {
      final bot = bots.bots.single;
      final set = await call(bot, 'bot_later', {
        'minutes': 90,
        'note': 'Ask how the interview went',
      });
      expect(set['isError'], isNot(isTrue));
      expect('${set['content']}', contains('15:30'));
      expect(bots.laters(bot).single.at, DateTime(2026, 10, 29, 15, 30));
      await pumpEventQueue();
      expect(store.preferences['later'], {
        'assistant': [
          {
            'at': DateTime(2026, 10, 29, 15, 30).millisecondsSinceEpoch,
            'note': 'Ask how the interview went',
          },
        ],
      });
      // Not before its time.
      now = DateTime(2026, 10, 29, 15);
      bots.deliver();
      expect(bots.threadOf(bot)!.session.itemCount, 0);
      now = DateTime(2026, 10, 29, 15, 31);
      bots.deliver();
      final note = bots.threadOf(bot)!.session.itemAt(0) as UserMessageItem;
      expect(ChatCodec.botEvent(note), contains('Ask how the interview went'));
      expect(ChatCodec.botEvent(note), contains('Now: Thursday'));
      expect(bots.laters(bot), isEmpty);

      // At night too: the hour is its to mind, as it is told.
      now = DateTime(2026, 10, 29, 22, 30);
      await call(bot, 'bot_later', {'minutes': 60, 'note': 'Remind of x'});
      expect(bots.laters(bot).single.at, DateTime(2026, 10, 29, 23, 30));
      expect(botEvents, contains('Mind the time'));
      expect(
        (await call(bot, 'bot_later', {'minutes': 0, 'note': 'x'}))['isError'],
        isTrue,
      );
      // Every bot may: none is set up for it.
      final mia = bots.save(name: 'Mia', identity: '', abilities: {});
      expect(await offered(mia.folder), contains('bot_later'));
    });

    test('it keeps notes of itself, and sees its own picture', () async {
      final bot = bots.bots.single;
      await call(bot, 'bot_remember', {
        'about': 'self',
        'action': 'add',
        'text': 'Loves rainy days',
      });
      expect(bots.selfNotes(bot), '- Loves rainy days');
      expect(bots.memory(bot), isEmpty);
      expect(
        '${(await call(bot, 'bot_my_picture', {}))['content']}',
        contains("name's first letter"),
      );
      final png = base64.decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
        '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      );
      final pictured = bots.save(
        id: bot.id,
        name: bot.name,
        identity: bot.identity,
        abilities: bot.abilities,
        avatarImage: (bytes: png, type: 'image/png'),
      );
      final seen = await call(pictured, 'bot_my_picture', {});
      expect(
        (seen['content'] as List).map((c) => (c as Map)['type']),
        contains('image'),
      );
    });

    test('told what the user changed of it, its new picture to see', () async {
      final bot = bots.bots.single;
      final session = bots.threadFor(bot).session;
      final png = base64.decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
        '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      );
      bots.save(
        id: bot.id,
        name: '包包',
        signature: '今天也要开心',
        identity: bot.identity,
        abilities: bot.abilities.difference({BotAbility.browser}),
        avatarImage: (bytes: png, type: 'image/png'),
      );
      final note = [
        for (var i = 0; i < session.itemCount; i++) session.itemAt(i),
      ].whereType<UserMessageItem>().last;
      final told = ChatCodec.botEvent(note)!;
      expect(told, contains('Your name: now "包包".'));
      expect(told, contains('Your picture: a new one'));
      expect(told, contains('今天也要开心'));
      expect(told, contains('You may no longer: browser.'));
      expect(note.images, hasLength(1));
      // Nothing changed: nothing told.
      int notes() =>
          [for (var i = 0; i < session.itemCount; i++) session.itemAt(i)]
              .whereType<UserMessageItem>()
              .length;
      final count = notes();
      final now = bots.bots.single;
      bots.save(
        id: now.id,
        name: now.name,
        avatar: now.avatar,
        signature: now.signature,
        identity: now.identity,
        abilities: now.abilities,
      );
      expect(notes(), count);
    });

    test('what it remembers: kept by it, seen, changed and cleared', () async {
      final bot = bots.bots.single;
      Future<void> remember(String action, String text) =>
          ClaudeSdkTools.handle({
            'jsonrpc': '2.0',
            'id': 3,
            'method': 'tools/call',
            'params': {
              'name': 'bot_remember',
              'arguments': {'action': action, 'text': text},
            },
          }, ClaudeSdkCall(cwd: bot.folder));
      await remember('add', 'Name is Leo');
      await remember('add', 'Likes tea');
      expect(bots.memory(bot), '- Name is Leo\n- Likes tea');
      bots.setMemory(bot, 'Name is Leo');
      expect(bots.memory(bot), 'Name is Leo');
      bots.setMemory(bot, '');
      expect(bots.memory(bot), '');
    });

    test('it writes first of an agent done, in a note of the app\'s', () async {
      final bot = bots.bots.single;
      final agent = workspace.startAgent(workspace.projects.single);
      agent.session.send(const ComposerMessage(text: 'build it'));
      for (var i = 0; i < 300 && !agent.session.isStreaming; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      workspace.notifyListeners();
      // Its turn over (stopped, not to wait for the mock's whole script).
      agent.session.stop();
      for (var i = 0; i < 300 && agent.session.isStreaming; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      workspace.notifyListeners();
      now = now.add(const Duration(minutes: 2));
      bots.deliver();
      final note = bots.threadOf(bot)!.session.itemAt(0);
      expect(note, isA<UserMessageItem>());
      expect(
        ChatCodec.botEvent(note as UserMessageItem),
        contains('done: "${agent.title}"'),
      );
    });

    test('only the assistant is told of every agent; another, of those it '
        'started or wrote to', () async {
      final assistant = bots.bots.single;
      final mia = bots.save(
        name: 'Mia',
        identity: '',
        abilities: {BotAbility.viewChats},
      );
      Future<AgentThread> run() async {
        final agent = workspace.startAgent(workspace.projectAt(app));
        agent.session.send(const ComposerMessage(text: 'build it'));
        for (var i = 0; i < 300 && !agent.session.isStreaming; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        workspace.notifyListeners();
        return agent;
      }

      Future<void> finish(AgentThread agent) async {
        agent.session.stop();
        for (var i = 0; i < 300 && agent.session.isStreaming; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        workspace.notifyListeners();
        now = now.add(const Duration(minutes: 2));
        bots.deliver();
      }

      List<String> told(Bot bot) {
        final session = bots.threadFor(bot).session;
        return [
          for (var i = 0; i < session.itemCount; i++)
            if (session.itemAt(i) case final UserMessageItem item
                when ChatCodec.botEvent(item) != null)
              ChatCodec.botEvent(item)!,
        ];
      }

      final first = await run();
      await finish(first);
      expect(told(assistant), hasLength(1));
      expect(told(mia), isEmpty);
      // One it started: told of it.
      final second = await run();
      bots.watch(mia, second);
      await finish(second);
      expect(told(mia).single, contains('done: "${second.title}"'));
      await pumpEventQueue();
      expect(store.preferences['watching'], {
        mia.id: [BotTools.idOf(second)],
      });
    });

    test('it drops what it meant to come back to', () async {
      final bot = bots.bots.single;
      await call(bot, 'bot_later', {'minutes': 3, 'note': 'Remind of tea'});
      await call(bot, 'bot_later', {'minutes': 60, 'note': 'Ask about x'});
      final dropped = await call(bot, 'bot_cancel_later', {'note': 'TEA'});
      expect('${dropped['content']}', contains('Remind of tea'));
      expect([for (final l in bots.laters(bot)) l.note], ['Ask about x']);
      final none = await call(bot, 'bot_cancel_later', {'note': 'nope'});
      expect('${none['content']}', contains('Waiting:'));
      expect(botEvents, contains('Never send a message saying you won'));
    });

    test('the assistant looks after the other bots, and itself', () async {
      final assistant = bots.bots.single;
      final made = await call(assistant, 'bot_save_bot', {
        'name': '阿猫',
        'emoji': '🐱',
        'identity': '你是一只懒猫',
      });
      expect(made['isError'], isNot(isTrue));
      final cat = bots.bots.firstWhere((b) => b.name == '阿猫');
      expect(cat.avatar, '🐱');
      expect(cat.abilities, isEmpty);
      // Another's changed: it is told by whom.
      await call(assistant, 'bot_save_bot', {'bot': cat.id, 'signature': '困'});
      final catSession = bots.threadFor(cat).session;
      final note = [
        for (var i = 0; i < catSession.itemCount; i++) catSession.itemAt(i),
      ].whereType<UserMessageItem>().last;
      expect(ChatCodec.botEvent(note), contains('小宝 (the assistant'));
      expect(bots.byId(cat.id)!.identity, '你是一只懒猫');
      // Itself, a picture it made: cut square; not told what it did.
      final file = File('$app/made.png')
        ..writeAsBytesSync(
          base64.decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP4z8Dw'
            'HxkzoAsAAA8hD/EEN8afAAAAAElFTkSuQmCC',
          ),
        );
      final changed = await call(assistant, 'bot_save_bot', {
        'bot': assistant.id,
        'picture': file.path,
        'signature': '在呢',
      });
      expect(changed['isError'], isNot(isTrue), reason: '$changed');
      final self = bots.byId(assistant.id)!;
      expect(self.signature, '在呢');
      expect(isAvatarImage(self.avatar!), isTrue);
      final ownSession = bots.threadFor(self).session;
      expect(
        [for (var i = 0; i < ownSession.itemCount; i++) ownSession.itemAt(i)]
            .whereType<UserMessageItem>(),
        isEmpty,
      );
      // Not itself deleted; another, yes.
      expect(
        (await call(assistant, 'bot_delete_bot', {
          'bot': assistant.id,
        }))['isError'],
        isTrue,
      );
      await call(assistant, 'bot_delete_bot', {'bot': cat.id});
      expect(bots.byId(cat.id), isNull);
      // None but the assistant does so.
      final mia = bots.save(name: 'Mia', identity: '', abilities: {});
      expect((await call(mia, 'bot_list_bots', {}))['isError'], isTrue);
      expect(botInstructions(self, memory: ''), contains('<contacts>'));
      expect(botInstructions(mia, memory: ''), isNot(contains('<contacts>')));
    });

    test('the bots know who the user is, their picture to see', () async {
      final bot = bots.bots.single;
      expect(
        '${(await call(bot, 'bot_user_picture', {}))['content']}',
        contains('none'),
      );
      final png = base64.decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
        '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      );
      bots.setMe(const BotUser(name: 'Leo', signature: '写代码的'), (
        bytes: png,
        type: 'image/png',
      ));
      expect(bots.me.name, 'Leo');
      expect(bots.myPicture!.bytes, png);
      final seen = await call(bot, 'bot_user_picture', {});
      expect(
        (seen['content'] as List).map((c) => (c as Map)['type']),
        contains('image'),
      );
      final told = workspace.agentSetup!(bot.folder)!.workspace().instructions;
      expect(told, contains('Their name: Leo.'));
      expect(told, contains('写代码的'));
      await pumpEventQueue();
      expect((store.preferences['me'] as Map)['name'], 'Leo');
      // Its picture gone with it.
      bots.setMe(const BotUser(name: 'Leo'), null);
      expect(bots.myPicture, isNull);
      expect(
        folders.files.keys.where((f) => p.basename(f).startsWith('me-')),
        isEmpty,
      );
    });

    test('it tells of an agent at work a long while, once', () async {
      final bot = bots.bots.single;
      final agent = workspace.startAgent(workspace.projects.single);
      agent.session.send(const ComposerMessage(text: 'build it'));
      for (var i = 0; i < 300 && !agent.session.isStreaming; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      workspace.notifyListeners();
      addTearDown(agent.session.stop);
      now = now.add(const Duration(minutes: 29));
      bots.checkRunning();
      now = now.add(const Duration(minutes: 2));
      bots.checkRunning();
      now = now.add(const Duration(minutes: 2));
      bots.deliver();
      final session = bots.threadOf(bot)!.session;
      expect(
        ChatCodec.botEvent(session.itemAt(0) as UserMessageItem),
        contains('running: "${agent.title}"'),
      );
      expect(
        ChatCodec.botEvent(session.itemAt(0) as UserMessageItem),
        contains('running for 31 min'),
      );
      // Not again, while it runs on.
      now = now.add(const Duration(hours: 1));
      bots.checkRunning();
      now = now.add(const Duration(hours: 1));
      bots.deliver();
      expect([
        for (var i = 0; i < session.itemCount; i++)
          if (session.itemAt(i) case final UserMessageItem item
              when ChatCodec.botEvent(item) != null)
            item,
      ], hasLength(1));
    });
  });
}

Duration seconds(int n) => Duration(seconds: n);
Duration minutes(int n) => Duration(minutes: n);
