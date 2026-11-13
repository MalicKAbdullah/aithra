import 'package:aithra/src/ui/aithra_type.dart';
import 'package:aithra/src/ui/widgets/voice_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget orb({required bool reduceMotion, required ValueNotifier<int> words}) =>
      MaterialApp(
        theme: aithraTheme(Brightness.dark),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Center(
            child: VoiceOrb(
              mood: OrbMood.speaking,
              level: ValueNotifier(0),
              words: words,
            ),
          ),
        ),
      );

  testWidgets('animates on one ticker without rebuilding', (tester) async {
    final words = ValueNotifier(0);
    await tester.pumpWidget(orb(reduceMotion: false, words: words));
    expect(tester.hasRunningAnimations, isTrue);
    final element = tester.element(find.byType(CustomPaint).last);
    words.value++;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.element(find.byType(CustomPaint).last), same(element));
    expect(element.dirty, isFalse);
  });

  testWidgets('holds still when the system asks for reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(orb(reduceMotion: true, words: ValueNotifier(0)));
    expect(tester.hasRunningAnimations, isFalse);
  });
}
