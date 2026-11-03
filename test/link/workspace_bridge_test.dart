import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/models/codex/codex_service.dart';
import 'package:baocode/models/codex/codex_usage.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';

import 'package:bao_link/bao_link.dart';
import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:baocode/chat/chat_session.dart' show ComposerMessage, UserPlace;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

class _QuotaService extends CodexUnavailable {
  bool forced = false;
  bool fail = false, hang = false;
  String? hangProvider;
  String? upstreamError;

  @override
  String? error(String providerId, String accountId) => upstreamError;

  @override
  Future<void> refreshUsage(ModelProvider provider, {bool force = true}) async {
    forced = force;
    if (fail) throw StateError('刷新失败');
    if (hang || provider.id == hangProvider) await Completer<void>().future;
  }

  @override
  CodexUsage? usage(String providerId, String accountId) => CodexUsage(
    at: DateTime(2026),
    plan: 'Plus',
    primary: const CodexWindow(usedPercent: 47, minutes: 300),
  );

  @override
  ProviderAccount? accountFor(ModelProvider provider, {String? session}) =>
      provider.accounts.first;
}

/// A conversation of six turns (a prompt and an answer each), read three
/// at a time from its end: u4..u6, then u1..u3.
void main() {
  Map<String, Object?> prompt(String id) => {
    'type': 'user',
    'uuid': id,
    'message': {'role': 'user', 'content': id},
  };

  Map<String, Object?> answer(String id) => {
    'type': 'assistant',
    'uuid': 'a-$id',
    'message': {
      'id': 'm-$id',
      'role': 'assistant',
      'model': 'claude-opus-5-5',
      'content': [
        {'type': 'text', 'text': 'answer $id'},
      ],
    },
  };

  ClaudeHistoryPage page(List<String> ids, {String? earlier}) =>
      ClaudeHistoryPage([
        for (final id in ids) ...[prompt(id), answer(id)],
      ], earlier: earlier);

  final asked = <String?>[];

  late Workspace workspace;
  late FakeCli cli;
  late WorkspaceBridge bridge;
  late LinkPeer phone;
  late String id;
  final updates = <LinkSessionUpdate>[];

  setUp(() async {
    asked.clear();
    updates.clear();
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      create: (context) => ClaudeCodeKernel(
        descriptor,
        KernelContext(
          cwd: '/p',
          resume: SessionRecord(
            id: 's',
            title: 't',
            updatedAt: DateTime(2026),
            cwd: '/p',
          ),
        ),
        start: (_) async => cli = FakeCli(),
        readHistoryPage: (session, {required turns, before}) async {
          asked.add(before);
          return switch (before) {
            null => page(['u4', 'u5', 'u6'], earlier: 'u4'),
            'u4' => page(['u1', 'u2', 'u3']),
            _ => page(const []),
          };
        },
      ),
    );
    workspace = Workspace(
      projects: const [Project('p', '/p')],
      kernels: [descriptor],
    );
    final thread = workspace.startAgent(workspace.projects.first);
    thread.session.attach();
    await pumpEventQueue();
    id = WorkspaceBridge.idOf(thread);

    final LinkPeer desktop;
    (phone, desktop) = await peers();
    bridge = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      throttle: const Duration(milliseconds: 10),
    )..start();
    final sub = phone.events
        .where((e) => e.name == LinkEvents.session)
        .listen(
          (e) => updates.add(
            LinkSessionUpdate.fromJson(e.data! as Map<String, Object?>),
          ),
        );
    addTearDown(sub.cancel);
  });

  tearDown(() {
    bridge.dispose();
    workspace.dispose();
  });

  test('手机项目置顶更新桌面工作区与公开状态，取消可往返', () async {
    expect(bridge.state().projects.single.pinned, isFalse);
    await bridge.handle(LinkMethods.pinProject, {'project': '/p', 'pinned': true});
    expect(workspace.isPinnedProject(workspace.projects.single), isTrue);
    expect(bridge.state().projects.single.toJson()['pinned'], isTrue);
    await bridge.handle(LinkMethods.pinProject, {'project': '/p', 'pinned': false});
    expect(bridge.state().projects.single.pinned, isFalse);
  });

  test('未知项目置顶失败，不改变现有项目', () async {
    await expectLater(
      bridge.handle(LinkMethods.pinProject, {'project': '/missing', 'pinned': true}),
      throwsA(isA<LinkRemoteException>().having((error) => error.code, 'code', LinkErrors.notFound)),
    );
    expect(bridge.state().projects.single.pinned, isFalse);
  });

  test('手机额度只返回公开字段，刷新失败或超时保留快照', () async {
    final service = _QuotaService();
    final providers = ModelProviders.memory(
      providers: const [
        ModelProvider(
          id: '账号源',
          name: 'ChatGPT',
          protocol: ProviderProtocol.codex,
          accounts: [
            ProviderAccount(id: '账号甲', email: '用户甲', accountId: '敏感工作区'),
          ],
        ),
      ],
    );
    final (phonePeer, desktopPeer) = await peers();
    addTearDown(phonePeer.close);
    final quotaBridge = WorkspaceBridge(
      workspace: workspace,
      peer: desktopPeer,
      device: () => const DeviceInfo(name: '电脑', kind: 'mac', system: '测试'),
      providers: providers,
      codex: service,
      quotaTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(quotaBridge.dispose);
    final result = await quotaBridge.handle(LinkMethods.quota, {
      'provider': '账号源',
      'session': id,
      'refresh': true,
    }) as Map;
    expect(service.forced, isTrue);
    final account =
        ((result['providers'] as List).single['accounts'] as List).single
            as Map;
    expect(account['displayName'], '用户甲');
    expect(account['current'], isTrue);
    expect((account['windows'] as List).single['leftPercent'], 53);
    expect(jsonEncode(result), isNot(contains('敏感工作区')));
    expect(account.keys, isNot(contains('token')));
    final empty =
        await quotaBridge.handle(LinkMethods.quota, {'provider': '不存在'}) as Map;
    expect(empty['providers'], isEmpty);
    for (final hang in [false, true]) {
      service.fail = !hang;
      service.hang = hang;
      final snapshot = await quotaBridge.handle(LinkMethods.quota, {
        'session': '未知会话',
        'refresh': true,
      }) as Map;
      final accounts =
          (snapshot['providers'] as List).single['accounts'] as List;
      expect(accounts, isNotEmpty);
      expect((accounts.single as Map)['error'], hang ? '额度刷新超时' : '额度刷新失败');
    }
  });

  test('服务缓存的上游错误文本不外发，只回固定中文错误，刷新失败文案优先', () async {
    const marker = 'SYNTHETIC-SENSITIVE-MARKER';
    final service = _QuotaService()..upstreamError = '上游原始响应 $marker';
    final providers = ModelProviders.memory(
      providers: const [
        ModelProvider(
          id: '账号源',
          name: 'ChatGPT',
          protocol: ProviderProtocol.codex,
          accounts: [ProviderAccount(id: '账号甲', email: '用户甲')],
        ),
      ],
    );
    final (phonePeer, desktopPeer) = await peers();
    addTearDown(phonePeer.close);
    final quotaBridge = WorkspaceBridge(
      workspace: workspace,
      peer: desktopPeer,
      device: () => const DeviceInfo(name: '电脑', kind: 'mac', system: '测试'),
      providers: providers,
      codex: service,
      quotaTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(quotaBridge.dispose);
    Future<Map> ask(Map<String, Object?> params) async {
      final result = await quotaBridge.handle(LinkMethods.quota, params) as Map;
      expect(
        jsonEncode(result).contains(marker),
        isFalse,
        reason: '额度响应泄漏了上游错误文本（已隐去内容）',
      );
      return ((result['providers'] as List).single['accounts'] as List).single
          as Map;
    }

    expect((await ask({}))['error'], '额度状态异常');
    expect((await ask({'refresh': true}))['error'], '额度状态异常');
    expect((await ask({}))['at'], isNotNull, reason: '快照仍然保留');
    service.fail = true;
    expect((await ask({'refresh': true}))['error'], '额度刷新失败');
    service
      ..fail = false
      ..hang = true;
    expect((await ask({'refresh': true}))['error'], '额度刷新超时');
    service
      ..hang = false
      ..upstreamError = null;
    expect((await ask({'refresh': true}))['error'], isNull);
    expect((await ask({}))['error'], isNull);
  });

  test('一个额度源超时不把已完成的额度源标记为失败', () async {
    final service = _QuotaService()..hangProvider = 'slow';
    final providers = ModelProviders.memory(
      providers: [
        for (final source in ['fast', 'slow'])
          ModelProvider(
            id: source,
            name: source,
            protocol: ProviderProtocol.codex,
            accounts: const [ProviderAccount(id: 'account', email: '合成账号')],
          ),
      ],
    );
    final (phonePeer, desktopPeer) = await peers();
    addTearDown(phonePeer.close);
    final quotaBridge = WorkspaceBridge(
      workspace: workspace,
      peer: desktopPeer,
      device: () => const DeviceInfo(name: '电脑', kind: 'mac', system: '测试'),
      providers: providers,
      codex: service,
      quotaTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(quotaBridge.dispose);
    final result =
        await quotaBridge.handle(LinkMethods.quota, {'refresh': true}) as Map;
    final snapshots = result['providers'] as List;
    expect(((snapshots[0] as Map)['accounts'] as List).single['error'], isNull);
    expect(
      ((snapshots[1] as Map)['accounts'] as List).single['error'],
      '额度刷新超时',
    );
  });

  Future<LinkSessionUpdate> open([int? window]) async =>
      LinkSessionUpdate.fromJson(
        (await bridge.handle(LinkMethods.open, {
              'session': id,
              'window': ?window,
            }))!
            as Map<String, Object?>,
      );

  List<String> texts(List<Object?> items) => [
    for (final json in items)
      switch (ChatCodec.decode(json)) {
        UserMessageItem(:final text) => text,
        _ => '-',
      },
  ];

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();
  }

  group('without a window', () {
    test('gives everything, and says nothing of earlier', () async {
      final opened = await open();
      expect(opened.start, 0);
      expect(opened.count, 6);
      expect(opened.earlier, isNull);
      expect(opened.toJson().containsKey('earlier'), isFalse);
    });

    test('an earlier call is refused', () async {
      await open();
      expect(
        bridge.handle(LinkMethods.earlier, {'session': id}),
        throwsA(isA<LinkRemoteException>()),
      );
    });

    test(
      'is sent all again from the start once the desktop prepends',
      () async {
        await open();
        final session = workspace.threads.first.session;
        await session.loadEarlier();
        await settle();
        final update = updates.last;
        expect(update.start, 0);
        expect(update.count, 12);
        expect(update.earlier, isNull);
      },
    );
  });

  group('with a window', () {
    test('gives the last items, counted from the first of them', () async {
      final opened = await open(4);
      expect(opened.start, 0);
      expect(opened.count, 4);
      expect(texts(opened.items), ['u5', '-', 'u6', '-']);
      expect(opened.earlier, isTrue);
    });

    test('a window beyond the items has all, and no earlier', () async {
      final opened = await open(100);
      expect(opened.count, 6);
      // u3's history is not read yet.
      expect(opened.earlier, isTrue);
    });

    test('a new item is a delta counted from the first', () async {
      await open(4);
      final session = workspace.threads.first.session;
      session.send(const ComposerMessage(text: 'more'));
      await settle();
      final update = updates.last;
      expect(update.start, 4);
      expect(update.count, greaterThan(4));
      expect(texts(update.items).first, 'more');
    });

    test(
      'the desktop reading earlier changes nothing but what is known',
      () async {
        await open(4);
        final session = workspace.threads.first.session;
        await session.loadEarlier();
        await settle();
        // Nothing of the phone's items changed: no update, or one of nothing.
        for (final update in updates) {
          expect(update.items, isEmpty);
          expect(update.count, 4);
        }
        // Its next item lands after the window, not at the shifted index.
        session.send(const ComposerMessage(text: 'more'));
        await settle();
        expect(updates.last.start, 4);
      },
    );

    test('earlier gives the items before, oldest first', () async {
      await open(4);
      final reply =
          (await bridge.handle(LinkMethods.earlier, {
                'session': id,
                'count': 2,
              }))!
              as Map<String, Object?>;
      expect(texts(reply['items']! as List), ['u4', '-']);
      expect(reply['earlier'], isTrue);
      final more =
          (await bridge.handle(LinkMethods.earlier, {'session': id}))!
              as Map<String, Object?>;
      // The window reached the start: the desktop read earlier ones.
      expect(asked, [null, 'u4']);
      expect(texts(more['items']! as List), [
        'u1', '-', 'u2', '-', 'u3', '-', //
      ]);
      expect(more['earlier'], isFalse);
    });

    test('deltas stay right after earlier', () async {
      await open(2);
      await bridge.handle(LinkMethods.earlier, {'session': id, 'count': 4});
      updates.clear();
      final session = workspace.threads.first.session;
      session.send(const ComposerMessage(text: 'more'));
      await settle();
      // 2 + 4 items now; the new one comes right after them.
      expect(updates.last.start, 6);
      expect(texts(updates.last.items).first, 'more');
    });

    test(
      'earlier reads the history when the window reaches the first',
      () async {
        await open(6);
        expect(asked, [null]);
        final reply =
            (await bridge.handle(LinkMethods.earlier, {
                  'session': id,
                  'count': 4,
                }))!
                as Map<String, Object?>;
        expect(asked, [null, 'u4']);
        expect(texts(reply['items']! as List), ['u2', '-', 'u3', '-']);
        expect(reply['earlier'], isTrue);
      },
    );

    test('earlier of a session not followed is refused', () async {
      expect(
        bridge.handle(LinkMethods.earlier, {'session': id}),
        throwsA(isA<LinkRemoteException>()),
      );
    });
  });

  test('a message from the phone tells the agent so, unseen', () async {
    await bridge.handle(LinkMethods.send, {'session': id, 'text': 'go'});
    await settle();
    final content = (cli.users.last['message']! as Map)['content']! as List;
    expect(
      [for (final block in content) (block as Map)['text']],
      [UserPlace.phone.note, 'go'],
    );
  });

  test('streamed text goes as what was added, and adds up the same', () async {
    final mirror = LinkSessionMirror()
      ..opened(
        jsonDecode(
          jsonEncode(await bridge.handle(LinkMethods.open, {'session': id})),
        ) as Map<String, Object?>,
      );
    final wire = <Map<String, Object?>>[];
    final sub = phone.events
        .where((e) => e.name == LinkEvents.session)
        .listen((e) => wire.add(e.data! as Map<String, Object?>));
    addTearDown(sub.cancel);
    await bridge.handle(LinkMethods.send, {'session': id, 'text': 'go'});
    await settle();
    Future<void> stream(Map<String, Object?> event) async {
      cli.push({'type': 'stream_event', 'event': event});
      await settle();
    }

    await stream({
      'type': 'message_start',
      'message': {
        'id': 'm-live',
        'usage': {'input_tokens': 1},
      },
    });
    await stream({
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'text', 'text': ''},
    });
    for (final words in ['Once ', 'upon ', 'a ', 'time']) {
      await stream({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': words},
      });
    }
    final whole = [for (final update in wire) mirror.apply(update)];
    expect(whole, everyElement(isNotNull));
    expect(wire.where((w) => w['append'] != null), isNotEmpty);
    expect(wire.skip(1).where((w) => w['partial'] != true), isEmpty);

    final fresh = await open();
    final last = whole.last!;
    expect(last['count'], fresh.count);
    final items = last['items']! as List;
    expect(
      jsonEncode(items),
      jsonEncode(fresh.items.sublist(fresh.count - items.length)),
    );
    expect(jsonEncode(fresh.items), contains('Once upon a time'));
  });

  test('a task\'s output is watched: what was added, then all again', () async {
    var text = 'one\n';
    final sent = <LinkOutput>[];
    final watch = OutputWatch(
      session: 's',
      task: 't',
      text: text,
      read: () async => text,
      emit: sent.add,
      every: const Duration(milliseconds: 5),
    );
    addTearDown(watch.dispose);
    text += 'two\n';
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent.single.text, 'two\n');
    expect(sent.single.offset, text.length);
    expect(sent.single.reset, isFalse);

    // Cut and written again: the phone is sent its tail whole.
    text = 'fresh\n';
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent.last.reset, isTrue);
    expect(sent.last.text, 'fresh\n');

    // More at once than the phone keeps: its tail, whole.
    text += 'x' * (LinkLimits.output + 10);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent.last.reset, isTrue);
    expect(sent.last.text.length, LinkLimits.output);
    final count = sent.length;
    watch.dispose();
    text += 'more';
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent, hasLength(count));
  });

  test('a plan is not started while none awaits', () async {
    await open();
    expect(
      bridge.handle(LinkMethods.startPlan, {'session': id}),
      throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.notFound,
        ),
      ),
    );
  });

  group('edit', () {
    test('an answer is not a message to edit', () async {
      await open();
      expect(
        bridge.handle(LinkMethods.edit, {
          'session': id,
          'index': 1,
          'text': 'again',
        }),
        throwsA(
          isA<LinkRemoteException>().having(
            (e) => e.code,
            'code',
            LinkErrors.notFound,
          ),
        ),
      );
    });

    test('the index is counted from the phone\'s first item', () async {
      // a5, u6, a6: the phone's 1 is the session's u6.
      final first = await open(3);
      expect(texts(first.items), ['-', 'u6', '-']);
      await bridge.handle(LinkMethods.edit, {
        'session': id,
        'index': 1,
        'text': 'u6 again',
      });
      // Counted from the session's first, its 1 would be an answer.
      expect(
        bridge.handle(LinkMethods.edit, {
          'session': id,
          'index': 0,
          'text': 'a5 is no message',
        }),
        throwsA(isA<LinkRemoteException>()),
      );
    });
  });

  group('image', () {
    test('a file that is not a picture is refused', () async {
      expect(
        bridge.handle(LinkMethods.image, {'project': '/p', 'path': 'a.txt'}),
        throwsA(isA<LinkRemoteException>()),
      );
    });

    test('a picture not there is not found', () async {
      expect(
        bridge.handle(LinkMethods.image, {'project': '/p', 'path': 'x.png'}),
        throwsA(
          isA<LinkRemoteException>().having(
            (e) => e.code,
            'code',
            LinkErrors.notFound,
          ),
        ),
      );
    });
  });

  test('a bot\'s agent: its model the user picks, not how it asks', () async {
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      create: (context) =>
          ClaudeCodeKernel(descriptor, context, start: (_) async => FakeCli()),
    );
    final workspace = Workspace(kernels: [descriptor]);
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    final (_, desktop) = await peers();
    final withBots = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: bots,
    );
    addTearDown(withBots.dispose);
    final assistant = bots.bots.single;
    final thread = bots.threadFor(assistant);
    final session = WorkspaceBridge.idOf(thread);
    expect(
      withBots.handle(LinkMethods.choose, {
        'session': session,
        'kind': 'permission',
        'option': 'bypassPermissions',
      }),
      throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.unsupported,
        ),
      ),
    );
    final models = thread.session.models!;
    final other = models.options.firstWhere((o) => o != models.selected);
    await withBots.handle(LinkMethods.choose, {
      'session': session,
      'kind': 'model',
      'option': other.id,
    });
    expect(bots.byId('assistant')!.model, other.id);
    expect(
      withBots.state().bots.single,
      isA<LinkBot>().having((b) => b.model, 'model', other.label),
    );
  });

  test('a bot\'s picture: sent with it, asked for, kept', () async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    final (_, desktop) = await peers();
    final withBots = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: bots,
    );
    addTearDown(withBots.dispose);
    final jpeg = base64.encode([255, 216, 255, 1, 2, 3]);
    final made = (await withBots.handle(LinkMethods.saveBot, {
      'name': 'Mia',
      'identity': '',
      'abilities': <String>[],
      'avatarImage': {'data': jpeg, 'type': 'image/jpeg'},
    }) as Map)['bot'];
    final mia = LinkBot.fromJson(made as Map<String, Object?>);
    expect(mia.hasAvatarImage, isTrue);
    expect(mia.avatar, endsWith('.jpg'));
    expect(await withBots.handle(LinkMethods.botAvatar, {'bot': mia.id}), {
      'type': 'image/jpeg',
      'data': jpeg,
    });
    // Kept by its name as other things change.
    await withBots.handle(LinkMethods.saveBot, {
      'bot': mia.id,
      'name': 'Mia B.',
      'avatar': mia.avatar,
      'identity': '',
      'abilities': <String>[],
    });
    expect(bots.byId(mia.id)!.avatar, mia.avatar);
    // What is not a picture, or too large, is refused.
    for (final image in [
      {'data': jpeg, 'type': 'text/html'},
      {
        'data': base64.encode(List.filled(LinkLimits.avatar + 1, 0)),
        'type': 'image/png',
      },
    ]) {
      expect(
        withBots.handle(LinkMethods.saveBot, {
          'bot': mia.id,
          'name': 'Mia',
          'identity': '',
          'abilities': <String>[],
          'avatarImage': image,
        }),
        throwsA(isA<LinkRemoteException>()),
      );
    }
    // None for one with an emoji.
    expect(
      withBots.handle(LinkMethods.botAvatar, {'bot': 'assistant'}),
      throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.notFound,
        ),
      ),
    );
  });

  test('a bot\'s files open from its chat: by their full path', () async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    final (_, desktop) = await peers();
    final withBots = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'PC', kind: 'pc', system: 'Win'),
      bots: bots,
    );
    addTearDown(withBots.dispose);
    final folder = Directory.systemTemp.createTempSync('bot_files');
    addTearDown(() => folder.deleteSync(recursive: true));
    final pdf = File('${folder.path}/简历.pdf')
      ..writeAsBytesSync([37, 80, 68, 70, 0, 1, 2]);
    final notes = File('${folder.path}/notes.md')..writeAsStringSync('# Hi');
    // As its reply links them, though the bot is in no project.
    expect(
      await withBots.handle(LinkMethods.read, {
        'bot': 'assistant',
        'path': notes.path,
      }),
      containsPair('text', '# Hi'),
    );
    expect(
      await withBots.handle(LinkMethods.read, {
        'bot': 'assistant',
        'path': pdf.path,
      }),
      {'binary': true},
    );
    final download = await withBots.handle(LinkMethods.download, {
      'bot': 'assistant',
      'path': pdf.path,
    }) as Map;
    expect(base64.decode(download['data'] as String), pdf.readAsBytesSync());
    expect(
      withBots.handle(LinkMethods.read, {'bot': 'nobody', 'path': pdf.path}),
      throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.notFound,
        ),
      ),
    );
  });
}

/// A phone's end and a desktop's, connected.
Future<(LinkPeer, LinkPeer)> peers() async {
  final (a, b) = MemoryLinkConnection.pair(
    a: LinkIdentity.generate().id,
    b: LinkIdentity.generate().id,
  );
  final accepted = LinkPeer.accept(b);
  final connected = await LinkPeer.connect(a);
  return (connected, await accepted);
}
