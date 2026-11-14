import 'dart:math' as math;

import 'package:aithra/src/ui/aithra_type.dart';
import 'package:aithra/src/ui/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replies of every awkward shape render without a single layout or paint
/// error, at phone widths and device font scales, finished and while they
/// stream in one prefix at a time.
void main() {
  const widths = [280.0, 360.0, 412.0];
  const scales = [1.0, 1.3, 2.0];

  Widget host(
    String text, {
    required double width,
    required double scale,
    Animation<double>? caret,
  }) => MaterialApp(
    theme: aithraTheme(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: SelectionArea(
        child: SingleChildScrollView(
          child: Center(
            child: SizedBox(
              width: width - 40,
              child: MarkdownView(text, caret: caret),
            ),
          ),
        ),
      ),
    ),
  );

  final pieces = [
    '*',
    '**',
    '***',
    '_',
    '__',
    '~~',
    '`',
    '```',
    '````',
    r'$',
    r'$$',
    r'\(',
    r'\)',
    r'\[',
    r'\]',
    '[',
    ']',
    '(',
    ')',
    '<',
    '>',
    '|',
    '#',
    '- ',
    '1. ',
    '> ',
    '- [ ] ',
    '- [x] ',
    '\n',
    '\n\n',
    '  ',
    '\t',
    'word',
    'x_1',
    '__init__',
    'https://example.com/a_(b)',
    r'\*',
    r'\\',
    'é',
    '漢字',
    '😀',
    r'\frac{a}{b}',
    r'x^{2}',
    '|---|---|',
    ':--:',
    '---',
    'snake_case',
  ];

  List<String> pathological() {
    final rng = math.Random(42);
    final out = <String>[
      '',
      ' ',
      '\n\n\n',
      '*' * 500,
      '_' * 500,
      '`' * 300,
      r'$' * 300,
      '[' * 300,
      '|' * 300,
      '#' * 10,
      '> ' * 50,
      '- ' * 100,
      '1. ' * 100,
      '```\n' * 40,
      '~~~\n' * 40,
      '| a | b |\n|---|---|\n${'| x |\n' * 30}',
      '| ${List.filled(30, 'col').join(' | ')} |\n'
          '|${List.filled(30, '---').join('|')}|\n'
          '| ${List.filled(30, r'$x^2$').join(' | ')} |',
      '${'a' * 2000} ${'b' * 3000}',
      'https://${'x' * 500}.com',
      '\$${List.generate(80, (i) => 'x_{$i}').join('+')}\$',
      '\$\$\n${List.generate(80, (i) => 'x_{$i}').join('+')}\n\$\$',
      r'$\frac{1}{$ and $\begin{matrix}$ and \(\sqrt{\)',
      '```plot\n{"fn":["tan(x)"]}\n```',
      '```chart\n{"type":"bar"\n```',
      '```chart\n{"type":"pie","labels":["a"],"series":[{"data":[0]}]}\n```',
      '```plot\n',
      '- [x] ~~done~~ **[link](http://a)** `code` \$x\$',
      '> > > nested\n> - list\n> ```\n> code\n> ```',
      '${'  ' * 40}- deep',
      '\u200b\u200d\ufeff',
    ];
    while (out.length < 200) {
      final n = 1 + rng.nextInt(24);
      out.add(
        [for (var i = 0; i < n; i++) pieces[rng.nextInt(pieces.length)]].join(),
      );
    }
    return out;
  }

  const samples = [
    '# Trip plan\n\nHere is a **two-day** route with _snake_case_ names kept '
        'and a [map](https://example.com/map).\n\n| Day | Walk | km |\n'
        '|:----|:-----|---:|\n| 1 | Catbells | 6 |\n| 2 | Helvellyn `via` '
        r'Striding Edge | $12.5$ |'
        '\n\n- [x] Book the hostel\n- [ ] Pack waterproofs\n  and a warm layer\n'
        '1. First\n2. Second\n\n> Weather changes fast.\n> Check before you go.',
    r'The quadratic $ax^2+bx+c=0$ has roots'
        '\n\n\$\$\nx = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}\n\$\$\n\n'
        '```plot\n{"fn":["x^2-1","2x"],"x":[-3,3]}\n```\n\n'
        'and ~~never~~ always check `__init__` with ***care***.',
    '````md\n```python\nprint("hi")\n```\n````\n\n```chart\n'
        '{"type":"line","labels":["a","b","c"],"series":[{"name":"s",'
        '"data":[1,3,2]}]}\n```\nDone.',
  ];

  Future<void> expectClean(WidgetTester tester, String label) async {
    final error = tester.takeException();
    expect(error, isNull, reason: label);
  }

  testWidgets('pathological strings', (tester) async {
    final strings = pathological();
    for (final (i, s) in strings.indexed) {
      final width = widths[i % widths.length];
      final scale = scales[(i ~/ widths.length) % scales.length];
      await tester.pumpWidget(host(s, width: width, scale: scale));
      await expectClean(
        tester,
        '$width/$scale: ${s.length > 80 ? s.substring(0, 80) : s}',
      );
    }
  });

  testWidgets('every prefix of sample replies while streaming', (tester) async {
    final caret = AnimationController(vsync: tester, value: 1);
    addTearDown(caret.dispose);
    for (final sample in samples) {
      for (var n = 1; n <= sample.length; n++) {
        final config = n % (widths.length * scales.length);
        final width = widths[config % widths.length];
        final scale = scales[config ~/ widths.length];
        await tester.pumpWidget(
          host(
            sample.substring(0, n),
            width: width,
            scale: scale,
            caret: caret,
          ),
        );
        await expectClean(tester, '$width/$scale prefix $n');
      }
    }
  });

  testWidgets('finished samples at every width and scale', (tester) async {
    for (final sample in samples) {
      for (final width in widths) {
        for (final scale in scales) {
          await tester.pumpWidget(host(sample, width: width, scale: scale));
          await expectClean(tester, '$width/$scale');
        }
      }
    }
  });
}
