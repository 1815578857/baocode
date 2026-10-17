import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/theme/app_theme.dart';

/// A conversation held in a list, changed by hand.
class _Feed extends ChangeNotifier implements ChatFeed {
  _Feed(this.items, {this.streaming = false});

  List<ChatItem> items;
  bool streaming;
  bool unprompted = false;

  void update(
    List<ChatItem> next, {
    required bool streaming,
    bool unprompted = false,
  }) {
    items = next;
    this.streaming = streaming;
    this.unprompted = unprompted;
    notifyListeners();
  }

  @override
  int get itemCount => items.length;

  @override
  ChatItem itemAt(int index) => items[index];

  @override
  bool get isStreaming => streaming;

  @override
  bool get isUnprompted => unprompted;

  @override
  bool get canEditMessages => false;

  @override
  ({int index, ComposerDraft draft})? get editing => null;

  @override
  set editing(({int index, ComposerDraft draft})? value) {}

  @override
  void editMessage(int index, ComposerMessage message) {}

  @override
  VoidCallback? moveToBackgroundAt(int index) => null;

  @override
  VoidCallback? stopAt(int index) => null;
}

/// Turn [n]: its message, [steps] reads each with a word, and (once done)
/// its answer.
List<ChatItem> _turn(int n, {int steps = 30, bool done = true}) => [
  UserMessageItem(
    text: 'Question $n',
    worked: done ? const Duration(seconds: 65) : null,
  ),
  for (var i = 0; i < steps; i++) ...[
    ToolCallItem(kind: ToolKind.read, target: 't${n}_$i.dart'),
    AssistantTextItem('Turn $n step $i.'),
  ],
  if (done) AssistantTextItem('Answer $n.'),
];

Future<void> _pump(WidgetTester tester, ChatFeed feed) async {
  tester.view.physicalSize = const Size(1000, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: ChatHistoryView(feed: feed)),
    ),
  );
  await tester.pump();
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

/// Wheels the list up by [by].
Future<void> _wheelUp(WidgetTester tester, double by) async {
  tester.binding.handlePointerEvent(
    PointerScrollEvent(
      position: tester.getCenter(find.byType(ChatHistoryView)),
      scrollDelta: Offset(0, -by),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _text(String text) => find.textContaining(text, findRichText: true);

void main() {
  testWidgets('folded work counts for nothing before it is laid out', (
    tester,
  ) async {
    await _pump(tester, _Feed([for (var n = 0; n < 40; n++) ..._turn(n)]));
    final position = _position(tester);
    final estimated = position.maxScrollExtent;

    // Up to the top, every item laid out on the way.
    while (position.pixels > 0) {
      position.jumpTo(position.pixels - 500 < 0 ? 0 : position.pixels - 500);
      await tester.pump();
    }
    // Each folded step taken at a row's height, the estimate would be some
    // twenty times this.
    expect(estimated, lessThan(position.maxScrollExtent * 2));
  });

  testWidgets('a mouse wheel\'s notch moves the list its own distance over '
      'a few frames, as Chrome does, the next adding to where it was going; '
      'a trackpad\'s at once', (tester) async {
    await _pump(tester, _Feed([for (var n = 0; n < 10; n++) ..._turn(n)]));
    final position = _position(tester);
    final bottom = position.pixels;
    expect(bottom, position.maxScrollExtent);

    void wheel(double by, {PointerDeviceKind kind = PointerDeviceKind.mouse}) =>
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: tester.getCenter(find.byType(ChatHistoryView)),
            scrollDelta: Offset(0, by),
            kind: kind,
          ),
        );

    wheel(-100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // As far as the wheel says, as Chrome's.
    const step = 100.0;
    // On its way, not there yet.
    expect(position.pixels, lessThan(bottom));
    expect(position.pixels, greaterThan(bottom - step));
    wheel(-100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(position.pixels, closeTo(bottom - 2 * step, 0.5));

    final before = position.pixels;
    wheel(-100, kind: PointerDeviceKind.trackpad);
    await tester.pump();
    expect(position.pixels, closeTo(before - 100, 0.5));

    // Back down past the end: at the end, anchored again.
    wheel(1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('as Chrome\'s: a notch takes 200 ms, eased in and out; one '
      'more mid-way goes on at the speed it had, never stopping', (
    tester,
  ) async {
    await _pump(tester, _Feed([for (var n = 0; n < 10; n++) ..._turn(n)]));
    final position = _position(tester);
    final bottom = position.pixels;
    void wheel() => tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(ChatHistoryView)),
        scrollDelta: const Offset(0, -100),
      ),
    );

    wheel();
    await tester.pump();
    final moved = <double>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      moved.add(bottom - position.pixels);
    }
    // Slow, then fast, then slow: half way at half time.
    expect(moved[0], lessThan(5));
    expect(moved[5], closeTo(50, 6));
    expect(moved[11], lessThan(100));
    await tester.pump(const Duration(milliseconds: 16));
    expect(bottom - position.pixels, closeTo(100, 0.5));

    // Mid-way, another: the list keeps moving, and gets 200 further.
    final start = position.pixels;
    wheel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    wheel();
    var last = position.pixels;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(position.pixels, lessThan(last));
      last = position.pixels;
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(start - position.pixels, closeTo(200, 0.5));
  });

  group('a turn starting while the user reads further up', () {
    final history = [for (var n = 0; n < 3; n++) ..._turn(n)];

    /// History, then turn 3, under way: the user scrolls up into it, and
    /// it ends there.
    Future<_Feed> readTurnThatEnded(WidgetTester tester) async {
      final feed = _Feed([
        ...history,
        ..._turn(3, done: false),
      ], streaming: true);
      await _pump(tester, feed);
      await _wheelUp(tester, 600);
      feed.update([...history, ..._turn(3)], streaming: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return feed;
    }

    testWidgets('one the agent took up leaves them there, the turn open', (
      tester,
    ) async {
      final feed = await readTurnThatEnded(tester);
      final pixels = _position(tester).pixels;
      expect(_text('Turn 3 step '), findsWidgets);

      // A background task's report.
      for (final streaming in [true, true, false]) {
        feed.update(
          [...feed.items, AssistantTextItem('Noted ${feed.items.length}.')],
          streaming: streaming,
          unprompted: streaming,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(_position(tester).pixels, pixels);
      expect(_text('Turn 3 step '), findsWidgets);
    });

    testWidgets('one the user sent brings the bottom into view', (
      tester,
    ) async {
      final feed = await readTurnThatEnded(tester);

      feed.update([
        ...feed.items,
        const UserMessageItem(text: 'Next'),
      ], streaming: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final position = _position(tester);
      expect(position.pixels, position.maxScrollExtent);
    });
  });

  testWidgets('opened mid-turn, scrolled up, the next output leaves them', (
    tester,
  ) async {
    final history = [for (var n = 0; n < 3; n++) ..._turn(n)];
    final feed = _Feed([
      ...history,
      ..._turn(3, steps: 20, done: false),
    ], streaming: true);
    await _pump(tester, feed);
    await _wheelUp(tester, 600);
    final pixels = _position(tester).pixels;

    feed.update([
      ...history,
      ..._turn(3, steps: 21, done: false),
    ], streaming: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(_position(tester).pixels, pixels);
  });
}
