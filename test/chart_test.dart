import 'dart:math' as math;

import 'package:aithra/src/chat/chart_spec.dart';
import 'package:aithra/src/chat/expr.dart';
import 'package:aithra/src/ui/aithra_type.dart';
import 'package:aithra/src/ui/widgets/chart_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('expressions', () {
    double eval(String s, double x) => compileExpr(s)(x);

    test('precedence and associativity', () {
      expect(eval('1 + 2 * 3', 0), 7);
      expect(eval('2^3^2', 0), 512);
      expect(eval('-x^2', 3), -9);
      expect(eval('2^-1', 0), 0.5);
      expect(eval('(1 + 2) * 3', 0), 9);
      expect(eval('x**2', 4), 16);
      expect(eval('10 / 4 / 5', 0), 0.5);
    });

    test('juxtaposition multiplies', () {
      expect(eval('2x', 3), 6);
      expect(eval('3x^2', 2), 12);
      expect(eval('2sin(x)', math.pi / 2), closeTo(2, 1e-12));
      expect(eval('(x+1)(x-1)', 3), 8);
      expect(eval('2pi', 0), closeTo(2 * math.pi, 1e-12));
    });

    test('functions and constants', () {
      expect(eval('sqrt(x)', 9), 3);
      expect(eval('ln(e)', 0), closeTo(1, 1e-12));
      expect(eval('log(1000)', 0), closeTo(3, 1e-12));
      expect(eval('abs(x)', -2), 2);
      expect(eval('max(x, 1)', -5), 1);
      expect(eval('cbrt(-8)', 0), closeTo(-2, 1e-12));
      expect(eval('π', 0), math.pi);
      expect(eval('1e3 + 2.5E-1', 0), 1000.25);
    });

    test('undefined points are NaN, not errors', () {
      expect(eval('sqrt(x)', -1), isNaN);
      expect(eval('1/x', 0), double.infinity);
    });

    test('malformed input throws FormatException', () {
      for (final bad in [
        '',
        '2 +',
        'sin x',
        'foo(x)',
        '(x',
        'x)',
        'max(1)',
        'y',
        '2 # 3',
        '*',
      ]) {
        expect(() => compileExpr(bad), throwsFormatException, reason: bad);
      }
    });

    test('random input never throws anything but FormatException', () {
      final rng = math.Random(7);
      const alphabet = 'x0123456789.+-*/^() ,sincoqrtlgepabmx';
      for (var n = 0; n < 3000; n++) {
        final s = String.fromCharCodes([
          for (var i = 0; i < rng.nextInt(16); i++)
            alphabet.codeUnitAt(rng.nextInt(alphabet.length)),
        ]);
        try {
          compileExpr(s)(rng.nextDouble() * 10 - 5);
        } on FormatException {
          // Expected for most random strings.
        }
      }
    });
  });

  group('specs', () {
    test('a plot', () {
      final p =
          ChartSpec.parse(
                'plot',
                '{"fn":["sin(x)","y = x^2/4"],"x":[-6.28,6.28]}',
              )
              as PlotSpec;
      expect(p.functions, hasLength(2));
      expect(p.functions[1](2), 1);
      expect(p.xMin, -6.28);
      expect(p.sources, ['sin(x)', 'y = x^2/4']);
    });

    test('a bar chart and its data', () {
      final c =
          ChartSpec.parse(
                'chart',
                '{"type":"bar","title":"Sales","labels":["Q1","Q2"],'
                    '"series":[{"name":"2025","data":[3,5.5]}]}',
              )
              as DataChart;
      expect(c.type, ChartType.bar);
      expect(c.title, 'Sales');
      expect(c.tsv(), '\t2025\nQ1\t3\nQ2\t5.5');
    });

    test('invalid specs say what is wrong', () {
      for (final (lang, src) in [
        ('plot', 'not json'),
        ('plot', '[1]'),
        ('plot', '{"fn":"sin("}'),
        ('plot', '{"fn":"x","x":[3,1]}'),
        ('chart', '{"type":"donut","series":[{"data":[1]}]}'),
        ('chart', '{"type":"bar","labels":["a"],"series":[{"data":[1,2]}]}'),
        ('chart', '{"type":"bar","labels":["a"],"series":[{"data":["x"]}]}'),
        ('chart', '{"type":"pie","labels":["a"],"series":[{"data":[-1]}]}'),
        ('chart', '{"type":"scatter","series":[{"data":[1,2]}]}'),
      ]) {
        expect(
          () => ChartSpec.parse(lang, src),
          throwsFormatException,
          reason: src,
        );
      }
    });

    test('ticks follow 1-2-5', () {
      expect(niceTicks(0, 10).ticks, [0, 2, 4, 6, 8, 10]);
      expect(niceTicks(-1, 1, count: 4).ticks, [-1, -0.5, 0, 0.5, 1]);
      expect(niceTicks(0, 1000, count: 4).step, 200);
      expect(tickLabel(-0.5, 0.5), '−0.5');
      expect(tickLabel(0, 0.5), '0.0');
    });
  });

  group('rendering', () {
    Widget host(Widget child, {double width = 360}) => MaterialApp(
      theme: aithraTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

    const specs = [
      ('plot', '{"fn":["tan(x)","1/x","sqrt(x)"],"x":[-5,5]}'),
      ('plot', '{"fn":"sqrt(-1-x^2)"}'),
      ('plot', '{"fn":"x","x":[-1e-9,1e-9],"y":[-1,1]}'),
      (
        'chart',
        '{"type":"bar","labels":["Mon","Tue","Wed"],"series":[{"name":"a",'
            '"data":[3,-2,5]},{"name":"b","data":[1,1,1]}]}',
      ),
      (
        'chart',
        '{"type":"line","labels":["a","b","c","d"],"series":[{"data":[1,1,1,1]}]}',
      ),
      (
        'chart',
        '{"type":"pie","labels":["a","b","c","d","e","f","g","h"],'
            '"series":[{"data":[1,2,3,4,5,6,7,8]}]}',
      ),
      ('chart', '{"type":"scatter","series":[{"data":[[1,2],[1,2]]}]}'),
    ];

    for (final (lang, src) in specs) {
      testWidgets('draws $src and reads values off it', (tester) async {
        for (final width in [200.0, 360.0]) {
          await tester.pumpWidget(
            host(
              ChartBlock(language: lang, source: src, closed: true),
              width: width,
            ),
          );
          expect(find.byType(ChartCard), findsOneWidget);
          final box = tester.getRect(find.byType(CustomPaint).last);
          for (final f in [0.1, 0.5, 0.9]) {
            await tester.tapAt(
              Offset(box.left + box.width * f, box.top + box.height * f),
            );
            await tester.pump();
          }
          expect(tester.takeException(), isNull);
        }
      });
    }

    testWidgets('an unclosed fence shows a placeholder', (tester) async {
      await tester.pumpWidget(
        host(
          const ChartBlock(language: 'plot', source: '{"fn":', closed: false),
        ),
      );
      expect(find.text('Drawing…'), findsOneWidget);
    });

    testWidgets('an invalid spec shows its source and why', (tester) async {
      await tester.pumpWidget(
        host(
          const ChartBlock(
            language: 'chart',
            source: '{"type":"donut"}',
            closed: true,
          ),
        ),
      );
      expect(find.textContaining("Couldn't draw this"), findsOneWidget);
      expect(find.textContaining('"donut"'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
