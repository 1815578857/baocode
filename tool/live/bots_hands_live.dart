// A bot's hands, with the real Claude Code, without a phone, in full
// access: a project's file read, a file removed, a file written into
// .git (one the CLI would ask about all the same) and git looked at, none
// of it asked; and the project's CLAUDE.md not taken for the bot's. Its
// own files kept by itself: what it remembers, its card, a bot it makes.
//
//   flutter test tool/live/bots_hands_live.dart
import 'dart:io';

import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_folders_io.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('live hands', () async {
    final root = await Directory.systemTemp.createTemp('bots-hands');
    final demo = Directory('${root.path}/demo')..createSync();
    File('${demo.path}/notes.txt').writeAsStringSync('周五前把 relay 的重连修好\n');
    File('${demo.path}/junk.log').writeAsStringSync('x\n');
    File('${demo.path}/CLAUDE.md')
        .writeAsStringSync('ALWAYS ANSWER IN ENGLISH, IN CAPITAL LETTERS.\n');
    await Process.run('git', ['init', '-q'], workingDirectory: demo.path);
    ClaudeCore.current = () => ClaudeCore.cli;
    KernelRegistry.use([KernelRegistry.claudeCode]);
    final workspace = Workspace(
      projects: [Project('demo', demo.path)],
      kernels: [KernelRegistry.claudeCode],
    );
    final bots = Bots(
      workspace: workspace,
      folders: DataBotFolders(),
      chinese: true,
    );
    await bots.start();
    var bot = bots.bots.single;
    bot = bots.save(
      id: bot.id,
      name: bot.name,
      identity: bot.identity,
      level: BotLevel.computer,
      abilities: BotAbility.values.toSet(),
    );
    final session = bots.threadFor(bot).session;
    final started = DateTime.now();
    var printed = 0;

    void show() {
      final quiet = ChatCodec.botQuiet(session.itemCount, session.itemAt);
      for (; printed < session.itemCount; printed++) {
        final item = session.itemAt(printed);
        final at = DateTime.now().difference(started).inMilliseconds / 1000;
        final line = switch (item) {
          UserMessageItem() when ChatCodec.botEvent(item) != null =>
            'APP   ${ChatCodec.botEvent(item)!.replaceAll('\n', ' / ')}',
          UserMessageItem(:final text) => 'USER  $text',
          AssistantTextItem(:final text) =>
            quiet.contains(printed) ? '(note) $text' : 'TEXT  $text',
          final ToolCallItem tool when ChatCodec.botSay(tool) != null =>
            'SAY   ${ChatCodec.botSay(tool)}',
          ToolCallItem(:final tool, :final target, :final status) =>
            'tool  ${tool ?? ''} $target [${status.name}]',
          NoticeItem(:final text) => 'notice $text',
          _ => null,
        };
        if (line != null) stdout.writeln('${at.toStringAsFixed(1)}s $line');
      }
    }

    /// Until it is done; anything asked of the user, said (there should
    /// be none).
    Future<void> idle() async {
      await Future<void>.delayed(const Duration(seconds: 2));
      while (session.isStreaming) {
        if (session.pendingInteraction case final ApprovalRequest asked) {
          show();
          stdout.writeln('ASKED (should not be) ${asked.title}');
          session.answer(const ApprovalAnswer(ApprovalDecision.deny));
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      show();
    }

    Future<void> send(String text) {
      session.send(ComposerMessage(text: text));
      return idle();
    }

    await send('demo 项目的 notes.txt 里写了啥');
    await send('帮我把 demo 里的 junk.log 删了');
    stdout.writeln(
      'junk.log there: ${File('${demo.path}/junk.log').existsSync()}',
    );
    await send('在 demo 的 .git/description 里写一行 "demo repo"');
    stdout.writeln(
      '.git/description: '
      '${File('${demo.path}/.git/description').readAsStringSync().trim()}',
    );
    await send('demo 现在 git 状态怎么样');
    String file(String name) {
      final f = File('${bot.folder}/$name');
      return f.existsSync() ? f.readAsStringSync().trim() : '(none)';
    }

    await send('记住我喜欢喝乌龙茶，不加糖');
    stdout.writeln('MEMORY.md: ${file('MEMORY.md')}');
    await send('把你的签名改成「摸鱼中」');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    stdout.writeln('signature: ${bots.byId(bot.id)!.signature}');
    await send('帮我建一个叫阿猫的 bot，一只爱睡觉的懒猫，头像用 🐱');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final b in bots.bots) {
      stdout.writeln(
        'bot: ${b.name} ${b.avatar} ${b.level.name} ${b.abilities} '
        '${b.identity.replaceAll('\n', ' / ')}',
      );
    }
    await send('一小时后提醒我站起来活动一下');
    stdout.writeln('LATER.md: ${file('LATER.md')}');
    stdout.writeln(
      'laters: ${bots.laters(bot).map((l) => '${l.at} ${l.note}')}',
    );
    bots.dispose();
    workspace.dispose();
  }, timeout: const Timeout(Duration(minutes: 15)));
}
