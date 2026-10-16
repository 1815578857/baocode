import 'dart:async';

import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/theme/app_theme.dart';

import '../kernel_test.dart' show FakeCli;

/// Turns [from] to [to], a prompt and an answer each.
List<Map<String, Object?>> _turns(int from, int to) => [
  for (var n = from; n <= to; n++) ...[
    {
      'type': 'user',
      'uuid': 'u$n',
      'message': {'role': 'user', 'content': 'Question $n'},
    },
    {
      'type': 'assistant',
      'uuid': 'a$n',
      'message': {
        'id': 'm$n',
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Answer $n.\n\n${'More of it. ' * 40}'},
        ],
      },
    },
  ],
];

void main() {
  testWidgets('earlier turns go before the first shown, which stays where '
      'it is, not a frame of them shown in its place', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final earlier = Completer<ClaudeHistoryPage>();
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      create: (context) => ClaudeCodeKernel(
        descriptor,
        context,
        start: (_) async => FakeCli(),
        readHistoryPage: (session, {required turns, before}) async =>
            before == null
            ? ClaudeHistoryPage(_turns(11, 20), earlier: 'u11')
            : earlier.future,
      ),
    );
    final session = ChatSession(
      kernel: descriptor,
      kernels: [descriptor, ...MockKernels.all.skip(1)],
      kernelContext: KernelContext(
        cwd: '/p',
        resume: SessionRecord(
          id: 's',
          title: 't',
          updatedAt: DateTime(2026),
          cwd: '/p',
        ),
      ),
      historyCount: 0,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: ChatHistoryView(feed: session)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(session.hasEarlierHistory, isTrue);

    // Up to the top: the earlier turns are asked for.
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(session.loadingEarlier, isTrue);
    final first = find.textContaining('Question 11', findRichText: true).first;
    final top = tester.getTopLeft(first).dy;

    earlier.complete(ClaudeHistoryPage(_turns(1, 10)));
    // Every frame from the one they come in.
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump();
      expect(tester.getTopLeft(first).dy, moreOrLessEquals(top, epsilon: 1));
      // Nor a button in place of the spinner, as they come.
      expect(find.byType(TextButton), findsNothing);
    }
    expect(session.itemCount, 40);
    expect(session.hasEarlierHistory, isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
