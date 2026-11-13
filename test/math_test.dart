import 'package:aithra/src/chat/markdown.dart';
import 'package:aithra/src/ui/widgets/markdown_view.dart';
import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

const _plain = InlineStyle.plain;
const _math = InlineStyle.math;
const _display = InlineStyle.displayMath;

void main() {
  group('inline math', () {
    test(r'reads $…$ and \(…\)', () {
      expect(parseInline(r'Area is $\pi r^2$ here'), const [
        MdSpan('Area is ', _plain),
        MdSpan(r'\pi r^2', _math),
        MdSpan(' here', _plain),
      ]);
      expect(parseInline(r'so \(a+b\) holds'), const [
        MdSpan('so ', _plain),
        MdSpan('a+b', _math),
        MdSpan(' holds', _plain),
      ]);
    });

    test(r'reads $$…$$ and \[…\] inside a paragraph as display math', () {
      expect(parseInline(r'gives $$x^2$$ and \[y\]'), const [
        MdSpan('gives ', _plain),
        MdSpan('x^2', _display),
        MdSpan(' and ', _plain),
        MdSpan('y', _display),
      ]);
    });

    test('prices are not math', () {
      expect(parseInline(r'It costs $5 and $10 today'), const [
        MdSpan(r'It costs $5 and $10 today', _plain),
      ]);
      expect(parseInline(r'between $5-$10'), const [
        MdSpan(r'between $5-$10', _plain),
      ]);
      expect(parseInline(r'a $ b $ c'), const [MdSpan(r'a $ b $ c', _plain)]);
    });

    test(r'a price before real math does not swallow it', () {
      expect(parseInline(r'Pay $5 then solve $x$'), const [
        MdSpan(r'Pay $5 then solve ', _plain),
        MdSpan('x', _math),
      ]);
    });

    test(r'an escaped \$ is a dollar sign, not a delimiter', () {
      expect(parseInline(r'\$3 and \$4'), const [MdSpan(r'$3 and $4', _plain)]);
    });

    test('unclosed math while streaming stays plain text', () {
      expect(parseInline(r'Let $x^2 + '), const [
        MdSpan(r'Let $x^2 + ', _plain),
      ]);
      expect(parseInline(r'Then $$\frac{a}{'), const [
        MdSpan(r'Then $$\frac{a}{', _plain),
      ]);
      expect(parseInline(r'and \(a'), const [MdSpan(r'and \(a', _plain)]);
    });

    test('emphasis markers inside math are left alone', () {
      expect(parseInline(r'**sum** $a_1 * b_2$'), const [
        MdSpan('sum', InlineStyle.bold),
        MdSpan(' ', _plain),
        MdSpan('a_1 * b_2', _math),
      ]);
    });

    test('dollars inside inline code are code', () {
      expect(parseInline(r'run `echo $HOME$` now'), const [
        MdSpan('run ', _plain),
        MdSpan(r'echo $HOME$', InlineStyle.code),
        MdSpan(' now', _plain),
      ]);
    });
  });

  group('display math blocks', () {
    test(r'$$ on its own lines is a block', () {
      final b = parseMarkdown(
        'Quadratic:\n\$\$\nx = \\frac{-b}{2a}\n\$\$\nDone',
      );
      expect(b, hasLength(3));
      expect((b[1] as MdMath).tex, r'x = \frac{-b}{2a}');
      expect((b[2] as MdParagraph).text, 'Done');
    });

    test(r'a one-line $$…$$ and \[…\] are blocks', () {
      expect((parseMarkdown(r'$$E = mc^2$$').single as MdMath).tex, 'E = mc^2');
      expect((parseMarkdown(r'\[ a^2 \]').single as MdMath).tex, 'a^2');
    });

    test('an unclosed block streams as text until it closes', () {
      final partial = parseMarkdown('\$\$\nx = \\frac{1}{');
      expect(partial.single, isA<MdParagraph>());
      final done = parseMarkdown('\$\$\nx = \\frac{1}{2}\n\$\$');
      expect((done.single as MdMath).tex, r'x = \frac{1}{2}');
    });

    test('the preview keeps the LaTeX source', () {
      expect(plainPreview('\$\$\nE = mc^2\n\$\$'), 'E = mc^2');
    });
  });

  group('rendering', () {
    Widget host(String text) => MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: Scaffold(body: SizedBox(width: 320, child: MarkdownView(text))),
    );

    testWidgets('typesets inline and block math', (tester) async {
      await tester.pumpWidget(
        host(
          'Since \$a^2+b^2=c^2\$:\n\n\$\$\n\\int_0^1 x\\,dx = \\frac12\n\$\$',
        ),
      );
      expect(find.byType(Math), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('malformed LaTeX falls back to its source alone', (
      tester,
    ) async {
      await tester.pumpWidget(host(r'Good $x^2$ and bad $\frac{a}{$ end'));
      expect(tester.takeException(), isNull);
      expect(find.textContaining(r'\frac{a}{'), findsOneWidget);
    });

    testWidgets('a wide equation scrolls instead of overflowing', (
      tester,
    ) async {
      final wide = List.generate(40, (i) => 'x_{$i}').join('+');
      await tester.pumpWidget(host('\$\$\n$wide\n\$\$'));
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(MarkdownView),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
    });

    testWidgets('streaming text grows into math without errors', (
      tester,
    ) async {
      const full = r'Let $\sqrt{x}$ be $$\sum_{i=1}^n i$$ ok';
      for (var n = 1; n <= full.length; n++) {
        await tester.pumpWidget(host(full.substring(0, n)));
      }
      expect(tester.takeException(), isNull);
    });
  });
}
