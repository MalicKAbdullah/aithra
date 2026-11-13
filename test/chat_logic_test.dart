import 'package:aithra/src/chat/chat_models.dart';
import 'package:aithra/src/chat/context_builder.dart';
import 'package:aithra/src/chat/markdown.dart';
import 'package:aithra/src/voice/sentence_splitter.dart';
import 'package:aithra/src/voice/speech_service.dart';
import 'package:flutter_test/flutter_test.dart';

PromptMessage msg(int seq, String text, {bool user = true, int tokens = 1}) =>
    PromptMessage(seq: seq, isUser: user, text: text, tokens: tokens);

void main() {
  group('prompt planning', () {
    test('keeps everything when it fits', () {
      final plan = planPrompt(
        system: 'sys',
        history: [
          msg(0, 'hi', tokens: 5),
          msg(1, 'hello', user: false, tokens: 6),
          msg(2, 'how?', tokens: 6),
        ],
        contextTokens: 4096,
        replyTokens: 1024,
        systemTokens: 40,
        overheadTokens: 3,
      );
      expect(plan.messages.map((m) => m.seq), [0, 1, 2]);
      expect(plan.promptTokens, 40 + 3 + 5 + 6 + 6);
    });

    test('drops the oldest messages first, on exact counts', () {
      final plan = planPrompt(
        system: 'sys',
        history: [
          msg(0, 'a', tokens: 1000),
          msg(1, 'b', tokens: 1100),
          msg(2, 'c', tokens: 900),
          msg(3, 'newest', tokens: 10),
        ],
        contextTokens: 3000,
        replyTokens: 1024,
        systemTokens: 60,
        overheadTokens: 4,
      );
      expect(plan.messages.map((m) => m.seq), [2, 3]);
      expect(plan.promptTokens, 60 + 4 + 900 + 10);
    });

    test('always keeps the newest message', () {
      final plan = planPrompt(
        system: 'sys',
        history: [msg(0, 'long', tokens: 9000)],
        contextTokens: 2048,
        replyTokens: 1024,
        systemTokens: 10,
        overheadTokens: 2,
      );
      expect(plan.messages.single.seq, 0);
    });

    test('estimates scale with UTF-8 bytes', () {
      expect(estimateTokens('abcd', byteBoundTokensPerByte), 4);
      expect(estimateTokens('é', byteBoundTokensPerByte), 2);
      expect(estimateTokens('abcdefgh', 0.25), 2);
    });

    test('a message that fits is left as it is', () async {
      final m = msg(0, 'short', tokens: 5);
      expect(
        await fitMessage(m, room: 10, cost: (t) async => t.length),
        same(m),
      );
    });

    test('an over-long message is clipped in the middle to fit', () async {
      final text = 'START ${'x' * 20000} END';
      Future<int> cost(String t) async => estimateTokens(t, 0.3);
      final fitted = await fitMessage(
        msg(0, text, tokens: await cost(text)),
        room: 3000,
        cost: cost,
      );
      expect(fitted.tokens, lessThanOrEqualTo(3000));
      expect(fitted.tokens, await cost(fitted.text));
      expect(fitted.text, startsWith('START '));
      expect(fitted.text, endsWith(' END'));
      expect(fitted.text, contains('characters left out'));
    });

    test('with no room left the prompt cannot be fitted', () {
      expect(
        fitMessage(msg(0, 'hi', tokens: 1), room: 0, cost: (t) async => 1),
        throwsStateError,
      );
    });

    test('summarize once another turn would pass 80% of the context', () {
      expect(
        shouldSummarize(
          usedTokens: 2300,
          contextTokens: 4096,
          replyTokens: 1024,
        ),
        isTrue,
      );
      expect(
        shouldSummarize(
          usedTokens: 2200,
          contextTokens: 4096,
          replyTokens: 1024,
        ),
        isFalse,
      );
    });

    test('summary folds everything but the recent turns', () {
      final history = [for (var i = 0; i < 10; i++) msg(i, 'm$i')];
      expect(messagesToSummarize(history).map((m) => m.seq), [0, 1, 2, 3]);
      expect(messagesToSummarize(history.take(5).toList()), isEmpty);
    });

    test('system prompt includes instructions, memories, recall, summary', () {
      final p = buildSystemPrompt(
        SystemContext(
          now: DateTime(2026, 3, 4),
          aboutUser: 'I teach physics.',
          replyStyle: 'Be brief.',
          memories: ["User's name is Sam"],
          recalled: ['We discussed tide tables'],
          summary: 'Sam is planning a trip.',
        ),
      );
      expect(p, contains('Today is 2026-03-04.'));
      expect(p, contains('LaTeX'));
      expect(p, contains('know about them:\nI teach physics.'));
      expect(p, contains('respond:\nBe brief.'));
      expect(p, contains("- User's name is Sam"));
      expect(p, contains('- We discussed tide tables'));
      expect(p, endsWith('Sam is planning a trip.'));
      final bare = buildSystemPrompt(SystemContext(now: DateTime(2026)));
      expect(bare, isNot(contains('know about the user')));
      expect(bare, isNot(contains('custom instructions')));
    });

    test('an over-budget system prompt sheds recall, then memories, then '
        'shortens instructions, and keeps the summary', () async {
      final full = SystemContext(
        now: DateTime(2026),
        aboutUser: 'a' * 1000,
        replyStyle: 'b' * 1000,
        memories: [for (var i = 0; i < 8; i++) 'Memory $i'],
        recalled: const ['Recalled'],
        summary: 'The summary.',
      );
      Future<int> cost(String s) async => s.length;
      final first = buildSystemPrompt(full);

      final noRecall = await fitSystemPrompt(
        full,
        budget: first.length - 5,
        firstCost: first.length,
        cost: cost,
      );
      expect(noRecall, isNot(contains('Recalled')));
      expect(noRecall, contains('Memory 7'));

      final tight = await fitSystemPrompt(
        full,
        budget: 900,
        firstCost: first.length,
        cost: cost,
      );
      expect(tight, isNot(contains('Memory 0')));
      expect(tight.length, lessThanOrEqualTo(900));
      expect(tight, endsWith('The summary.'));

      expect(
        await fitSystemPrompt(
          full,
          budget: 1 << 20,
          firstCost: first.length,
          cost: cost,
        ),
        first,
      );
    });

    test('memories are shed from the end of the list, newest kept', () {
      final c = SystemContext(
        now: DateTime(2026),
        memories: const ['new', 'mid', 'old', 'oldest'],
      );
      expect(c.shed()!.memories, ['new', 'mid']);
      expect(c.shed()!.shed()!.memories, ['new']);
      expect(c.shed()!.shed()!.shed()!.memories, isEmpty);
      expect(c.shed()!.shed()!.shed()!.shed(), isNull);
    });

    test('summarize prompt labels speakers', () {
      final p = summarizePrompt('Earlier.', [
        (isUser: true, text: 'Hi'),
        (isUser: false, text: 'Hello'),
      ]);
      expect(p, contains('Earlier summary:\nEarlier.'));
      expect(p, contains('User: Hi\nAssistant: Hello'));
    });
  });

  test('titles come from the first line, shortened', () {
    expect(titleFrom('  Plan my week\nwith details'), 'Plan my week');
    expect(titleFrom(''), 'Image');
    expect(titleFrom('a' * 60).length, 48);
  });

  group('markdown', () {
    test('blocks', () {
      final b = parseMarkdown(
        '# Title\n\nSome *text*.\n- one\n  - two\n3. three\n> quote\n---\n```dart\nvoid main() {}\n```',
      );
      expect(b[0], isA<MdHeading>());
      expect((b[1] as MdParagraph).text, 'Some *text*.');
      expect((b[2] as MdListItem).marker, '•');
      expect((b[3] as MdListItem).indent, 1);
      expect((b[4] as MdListItem).marker, '3.');
      expect(b[5], isA<MdQuote>());
      expect(b[6], isA<MdRule>());
      final code = b[7] as MdCode;
      expect(code.language, 'dart');
      expect(code.code, 'void main() {}');
      expect(code.closed, isTrue);
    });

    test('an unclosed fence while streaming is still code', () {
      final b = parseMarkdown('Here:\n```py\nprint(1)');
      final code = b.last as MdCode;
      expect(code.code, 'print(1)');
      expect(code.closed, isFalse);
    });

    test('inline styles', () {
      expect(parseInline('a **b** *c* `d` [e](http://x) ***f***'), const [
        MdSpan('a ', InlineStyle.plain),
        MdSpan('b', InlineStyle.bold),
        MdSpan(' ', InlineStyle.plain),
        MdSpan('c', InlineStyle.italic),
        MdSpan(' ', InlineStyle.plain),
        MdSpan('d', InlineStyle.code),
        MdSpan(' ', InlineStyle.plain),
        MdSpan('e', InlineStyle.link),
        MdSpan(' ', InlineStyle.plain),
        MdSpan('f', InlineStyle.boldItalic),
      ]);
    });

    test('a lone asterisk stays plain', () {
      expect(parseInline('2 * 3 = 6'), const [
        MdSpan('2 * 3 = 6', InlineStyle.plain),
      ]);
    });
  });

  group('sentence splitter', () {
    test('emits sentences as soon as they complete', () {
      final s = SentenceSplitter();
      expect(s.add('Hello there'), isEmpty);
      expect(s.add('. How are'), ['Hello there.']);
      expect(s.add(' you? I am'), ['How are you?']);
      expect(s.flush(), ['I am']);
    });

    test('skips code blocks and strips markdown', () {
      final s = SentenceSplitter();
      final out = [
        ...s.add('Use **this**:\n\n```\nx = 1. y = 2.\n```\n\nDone. '),
        ...s.flush(),
      ];
      expect(out, ['Use this:', 'Done.']);
    });

    test('speakable removes links and list markers', () {
      expect(speakable('- see [docs](http://x) `now`'), 'see docs now');
    });
  });

  test('speech latencies come from recognizer event times', () {
    final clock = SpeechClock()
      ..on('ready', 0)
      ..on('begin', 100)
      ..on('partial', 380)
      ..on('partial', 600)
      ..on('end', 1500)
      ..on('final', 1720);
    final m = clock.metrics;
    expect(m.firstPartialMs, 280);
    expect(m.finalMs, 220);
    clock.reset();
    expect(clock.metrics.firstPartialMs, isNull);
  });

  test('missing language pack errors are recognised', () {
    expect(languageMissingErrors.contains(13), isTrue);
    expect(speechErrorMessage(9), 'Microphone permission is needed');
  });

  group('chat list', () {
    test('preview drops Markdown and collapses whitespace', () {
      expect(
        plainPreview('## Steps\n- Run `pip install x`\n\n```sh\nls -la\n```'),
        'Steps Run pip install x ls -la',
      );
    });

    test('dates read as time, Yesterday, weekday, day month, then year', () {
      final now = DateTime(2026, 11, 13, 16); // a Friday
      expect(friendlyDate(DateTime(2026, 11, 13, 9, 5), now), '09:05');
      expect(friendlyDate(DateTime(2026, 11, 12, 23), now), 'Yesterday');
      expect(friendlyDate(DateTime(2026, 11, 9, 8), now), 'Mon');
      expect(friendlyDate(DateTime(2026, 11, 4), now), '4 Nov');
      expect(friendlyDate(DateTime(2025, 12, 30), now), '30 Dec 2025');
    });
  });
}
