import 'package:aithra/src/chat/chat_session.dart';
import 'package:aithra/src/ui/widgets/markdown_view.dart';
import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake engine streams a long Markdown reply into [StreamingText] at a
/// fixed token rate while 200 finished messages sit in the list. Measures
/// how long each frame takes to build and lay out, and checks that finished
/// messages are not rebuilt while streaming.
const _reply = '''
## Plan

Here is a **step by step** plan with `inline code` and a list:

- First, gather the *ingredients* you need.
- Then preheat the oven to 180 degrees.
  - Use the middle rack.
1. Mix everything.
2. Bake for 25 minutes.

```dart
void main() {
  for (var i = 0; i < 10; i++) {
    print('tick \$i');
  }
}
```

> Tip: let it rest before slicing.

That is all. Enjoy your bake, and tell me how it turns out!
''';

int _builds = 0;

class _CountingMessage extends StatelessWidget {
  const _CountingMessage(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    _builds++;
    return Padding(padding: const EdgeInsets.all(8), child: MarkdownView(text));
  }
}

Future<Map<String, double>> _run(
  WidgetTester tester,
  int tokensPerSecond,
) async {
  final streaming = StreamingText();
  _builds = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: Scaffold(
        body: ListView.builder(
          reverse: true,
          itemCount: 201,
          itemBuilder: (context, i) => i == 0
              ? RepaintBoundary(
                  child: ValueListenableBuilder<String>(
                    valueListenable: streaming,
                    builder: (context, text, _) => MarkdownView(text),
                  ),
                )
              : _CountingMessage('Message $i with **bold** text and `code`.'),
        ),
      ),
    ),
  );
  final buildsBefore = _builds;
  // ~4 characters per token.
  final tokens = RegExp(
    r'.{1,4}',
    dotAll: true,
  ).allMatches(_reply).map((m) => m[0]!).toList();
  final frameMs = <double>[];
  const frame = Duration(microseconds: 8333); // 120 Hz
  var due = 0.0;
  final perFrame = tokensPerSecond / 120;
  for (var f = 0; f < 120 * 20 && tokens.isNotEmpty; f++) {
    due += perFrame;
    while (due >= 1 && tokens.isNotEmpty) {
      streaming.add(tokens.removeAt(0));
      due -= 1;
    }
    final sw = Stopwatch()..start();
    await tester.pump(frame);
    frameMs.add(sw.elapsedMicroseconds / 1000);
  }
  frameMs.sort();
  final rebuilds = _builds - buildsBefore;
  streaming.dispose();
  return {
    'frames': frameMs.length.toDouble(),
    'avg': frameMs.reduce((a, b) => a + b) / frameMs.length,
    'p95': frameMs[(frameMs.length * 0.95).floor()],
    'max': frameMs.last,
    'finishedMessageRebuilds': rebuilds.toDouble(),
  };
}

void main() {
  for (final rate in [15, 60]) {
    testWidgets('streaming at $rate tok/s rebuilds only the streaming bubble', (
      tester,
    ) async {
      final r = await _run(tester, rate);
      // ignore: avoid_print
      print(
        'streaming $rate tok/s: ${r['frames']!.round()} frames, '
        'avg ${r['avg']!.toStringAsFixed(2)} ms, p95 ${r['p95']!.toStringAsFixed(2)} ms, '
        'max ${r['max']!.toStringAsFixed(2)} ms, finished-message rebuilds ${r['finishedMessageRebuilds']!.round()}',
      );
      expect(r['finishedMessageRebuilds'], 0);
    });
  }
}
