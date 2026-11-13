import 'package:aithra/src/chat/chat_models.dart';
import 'package:aithra/src/chat/context_builder.dart';
import 'package:aithra/src/chat/markdown.dart';
import 'package:aithra/src/memory/fact_extractor.dart';
import 'package:aithra/src/voice/sentence_splitter.dart';
import 'package:aithra/src/voice/speech_service.dart';
import 'package:flutter_test/flutter_test.dart';

PromptMessage msg(int seq, String text, {bool user = true, int images = 0}) =>
    PromptMessage(seq: seq, isUser: user, text: text, imageCount: images);

void main() {
  group('prompt planning', () {
    test('keeps everything when it fits', () {
      final plan = planPrompt(
        system: 'sys',
        history: [msg(0, 'hi'), msg(1, 'hello', user: false), msg(2, 'how?')],
        contextTokens: 4096,
        replyTokens: 1024,
      );
      expect(plan.messages.map((m) => m.seq), [0, 1, 2]);
    });

    test('drops the oldest messages first when over budget', () {
      final long = 'x' * 3200; // ~1000 tokens
      final plan = planPrompt(
        system: 'sys',
        history: [msg(0, long), msg(1, long), msg(2, long), msg(3, 'newest')],
        contextTokens: 3000,
        replyTokens: 1024,
      );
      expect(plan.messages.map((m) => m.seq), [2, 3]);
      expect(plan.estimatedTokens, lessThanOrEqualTo(3000 - 1024));
    });

    test('always keeps the newest message', () {
      final plan = planPrompt(
        system: 'sys',
        history: [msg(0, 'y' * 20000)],
        contextTokens: 2048,
        replyTokens: 1024,
      );
      expect(plan.messages.single.seq, 0);
    });

    test('images count toward the budget', () {
      expect(estimateTokens('', images: 2), 6 + 2 * imageTokens);
    });

    test('summarize when the context is 70% full', () {
      expect(shouldSummarize(usedTokens: 2900, contextTokens: 4096), isTrue);
      expect(shouldSummarize(usedTokens: 2800, contextTokens: 4096), isFalse);
    });

    test('summary folds everything but the recent turns', () {
      final history = [for (var i = 0; i < 10; i++) msg(i, 'm$i')];
      expect(messagesToSummarize(history).map((m) => m.seq), [0, 1, 2, 3]);
      expect(messagesToSummarize(history.take(5).toList()), isEmpty);
    });

    test('system prompt includes memories, recall and summary', () {
      final p = buildSystemPrompt(
        now: DateTime(2026, 3, 4),
        memories: ["User's name is Sam"],
        recalled: ['We discussed tide tables'],
        summary: 'Sam is planning a trip.',
      );
      expect(p, contains('Today is 2026-03-04.'));
      expect(p, contains("- User's name is Sam"));
      expect(p, contains('- We discussed tide tables'));
      expect(p, endsWith('Sam is planning a trip.'));
      final bare = buildSystemPrompt(
        now: DateTime(2026),
        memories: const [],
        recalled: const [],
        summary: null,
      );
      expect(bare, isNot(contains('know about the user')));
    });

    test('summarize prompt labels speakers', () {
      final p = summarizePrompt('Earlier.', [
        msg(0, 'Hi'),
        msg(1, 'Hello', user: false),
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

  group('fact suggestions', () {
    test('recognise first-person facts', () {
      expect(suggestFacts('Hi! My name is Sam Lee.'), [
        "User's name is Sam Lee",
      ]);
      expect(suggestFacts('I live in Lahore'), ['User lives in Lahore']);
      expect(suggestFacts("I'm allergic to peanuts."), [
        'User is allergic to peanuts',
      ]);
      expect(suggestFacts('I really love hiking in the hills'), [
        'User loves hiking in the hills',
      ]);
      expect(suggestFacts('Remember that my flight is on Friday'), [
        'My flight is on Friday',
      ]);
      expect(suggestFacts("My dog's name is Biscuit"), [
        "User's dog is Biscuit",
      ]);
      expect(suggestFacts('I work as a nurse.'), ['User works as a nurse']);
    });

    test('ignore ordinary questions', () {
      expect(suggestFacts('What is the weather like on Mars?'), isEmpty);
    });

    test('one suggestion per sentence, deduplicated', () {
      expect(suggestFacts('My name is Sam. I live in Oslo. My name is Sam.'), [
        "User's name is Sam",
        'User lives in Oslo',
      ]);
    });
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
