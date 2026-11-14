import 'package:aithra/src/chat/chat_models.dart';
import 'package:aithra/src/ui/widgets/markdown_view.dart';
import 'package:aithra/src/ui/widgets/message_bubble.dart';
import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

/// Inline math lays out in every reply shape a chat list can hold: repeated
/// equations, chips and the caret beside math, streaming, narrow widths and
/// device font scales. Every FlutterError of a frame is collected, not just
/// the first, so a cascade fails with its cause.
void main() {
  const scales = [1.0, 1.15, 1.3, 2.0];
  const widths = [96.0, 200.0, 360.0];

  Widget host(
    List<String> replies, {
    double width = 320,
    double scale = 1,
    Animation<double>? caret,
  }) => MaterialApp(
    theme: AppTheme.build(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: ListView(
            children: [
              for (final (i, r) in replies.indexed)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: MarkdownView(
                    r,
                    caret: i == replies.length - 1 ? caret : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<List<FlutterErrorDetails>> pumpCollecting(
    WidgetTester tester,
    Widget widget,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await tester.pumpWidget(widget);
      await tester.pump();
    } finally {
      FlutterError.onError = previous;
    }
    return errors;
  }

  /// An equation piece wider than the whole line cannot wrap; it lays out
  /// at its natural width and debug builds paint flutter_math_fork's
  /// overflow stripe. That warning is the only error [overflow] allows.
  void expectClean(List<FlutterErrorDetails> errors, {bool overflow = false}) {
    final messages = [
      for (final e in errors)
        if (!overflow ||
            !RegExp(
              r'^A RenderLine overflowed by [\d.]+ pixels on the right\.$',
            ).hasMatch(e.exceptionAsString()))
          e.exceptionAsString(),
    ];
    expect(
      messages,
      isEmpty,
      reason: errors.isEmpty ? null : errors.first.toString(),
    );
  }

  const replies = [
    r'The same $x^2$ twice: $x^2$ and again $x^2$.',
    r'Angle \(\theta\) with $\frac{a}{b} = c$ and **bold** $y$ then `code` $z$.',
    r'A matrix $\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}$ inline.',
    r'Display inline $$\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$$ in text.',
    r'- item with $a_1 + a_2 = b$',
    r'> quoted $\sqrt{2} \approx 1.414$',
  ];

  group('inline math layout', () {
    testWidgets('an equation repeated in one paragraph', (tester) async {
      expectClean(await pumpCollecting(tester, host([r'$x^2$ and $x^2$'])));
      expect(find.byType(Math), findsNWidgets(2));
    });

    testWidgets('the same equation in two replies', (tester) async {
      expectClean(
        await pumpCollecting(tester, host([r'So $x^2$.', r'Yes, $x^2$.'])),
      );
    });

    testWidgets('a reply rebuilt next to a copy of itself', (tester) async {
      const r = r'Area $\pi r^2$ here';
      expectClean(await pumpCollecting(tester, host([r])));
      expectClean(await pumpCollecting(tester, host([r, r])));
      expectClean(await pumpCollecting(tester, host([r])));
    });

    for (final scale in scales) {
      for (final width in widths) {
        testWidgets('replies at scale $scale, width $width', (tester) async {
          expectClean(
            await pumpCollecting(
              tester,
              host(replies, width: width, scale: scale),
            ),
            overflow: width < 120,
          );
        });
      }
    }

    testWidgets('a formula wider than the line', (tester) async {
      final wide = List.generate(30, (i) => 'x_{$i}^{2}').join('');
      for (final scale in scales) {
        expectClean(
          await pumpCollecting(
            tester,
            host(
              ['Wide \$$wide\$ and `chip` **bold**'],
              width: 96,
              scale: scale,
            ),
          ),
          overflow: true,
        );
        // The reply keeps the list's width (96 less its 8 px padding).
        expect(tester.getSize(find.byType(MarkdownView)).width, 80);
      }
    });

    testWidgets('streaming with the caret, through partial LaTeX', (
      tester,
    ) async {
      final caret = AnimationController(vsync: tester, value: 1);
      addTearDown(caret.dispose);
      const full =
          r'Let $x^2$ and \(\theta\) give $\frac{a}{b}$, `k` then $x^2$ '
          r'with $\begin{matrix} 1 & 2 \end{matrix}$ done';
      for (final scale in scales) {
        for (var n = 1; n <= full.length; n += 3) {
          expectClean(
            await pumpCollecting(
              tester,
              host(
                [full, full.substring(0, n)],
                width: 200,
                scale: scale,
                caret: caret,
              ),
            ),
          );
        }
      }
    });

    testWidgets('inline math is scaled once by the font scale', (tester) async {
      Future<double> heightAt(double scale) async {
        expectClean(
          await pumpCollecting(tester, host([r'$\frac{a}{b}$'], scale: scale)),
        );
        return tester.getSize(find.byType(Math)).height;
      }

      final one = await heightAt(1);
      final two = await heightAt(2);
      // Math's own size is unscaled; the paragraph scales its placeholder.
      expect(two, closeTo(one, 0.01));
    });

    testWidgets('a bad equation shows its source alone', (tester) async {
      expectClean(
        await pumpCollecting(
          tester,
          host([r'Good $x^2$, bad $\frac{a}{$ and good $x^2$ end']),
        ),
      );
      expect(find.textContaining(r'\frac{a}{'), findsOneWidget);
      expect(find.byType(Math), findsNWidgets(3));
    });
  });

  group('a long chat', () {
    const kinds = [
      r'Use $x^2$ here, and $x^2$ again with `x` and **bold**.',
      '## Steps\n\n- one \$a+b\$\n- two \$a+b\$\n  - nested `code`\n1. first\n2. second',
      '```dart\nvoid main() => print(1);\n```\n\nThen \$\\frac{1}{2}\$.',
      '| a | b |\n|---|---|\n| \$x\$ | \$y\$ |\n| 1 | 2 |',
      '\$\$\n\\int_0^1 x\\,dx = \\frac12\n\$\$\n\nSo \\(\\theta = \\pi\\).',
      '> quote with \$\\sqrt{2}\$\n\n---\n\nPlain text reply.',
    ];

    testWidgets('opens and scrolls through hundreds of messages', (
      tester,
    ) async {
      const count = 400;
      final messages = [
        for (var i = 0; i < count; i++)
          ChatMessage(
            id: i,
            seq: i,
            role: i.isEven ? Role.user : Role.model,
            content: i.isEven ? 'Question $i' : kinds[i % kinds.length],
            imageIds: const [],
            created: DateTime(2026),
          ),
      ];
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      for (final scale in [1.0, 1.3]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: ListView.builder(
                key: ValueKey(scale),
                reverse: true,
                itemCount: count,
                itemBuilder: (context, i) => MessageBubble(
                  key: ValueKey(messages[count - 1 - i].seq),
                  message: messages[count - 1 - i],
                  onLongPress: () {},
                ),
              ),
            ),
          ),
        );
        // Lazy: only the visible replies and the cache extent are built.
        expect(
          find.byType(MarkdownView).evaluate().length,
          lessThan(count ~/ 10),
        );
        for (var step = 0; step < 120; step++) {
          await tester.drag(find.byType(ListView), const Offset(0, 900));
          await tester.pump();
        }
        expect(find.text('Question 0'), findsOneWidget);
        for (var step = 0; step < 120; step++) {
          await tester.drag(find.byType(ListView), const Offset(0, -900));
          await tester.pump();
        }
      }
      FlutterError.onError = previous;
      expectClean(errors);
    });
  });
}
