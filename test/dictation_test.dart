import 'dart:async';

import 'package:aithra/src/platform/native.dart';
import 'package:aithra/src/ui/aithra_type.dart';
import 'package:aithra/src/ui/widgets/composer.dart';
import 'package:aithra/src/ui/widgets/recording_bar.dart';
import 'package:aithra/src/voice/dictation.dart';
import 'package:aithra/src/voice/speech_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Kotlin speech bridge as Dart sees it: the test pushes recognizer
/// events and sees which calls were made.
class FakeSpeech extends NativeBridge {
  FakeSpeech._(this._events)
    : super(channel: const MethodChannel('fake'), events: _events.stream);
  factory FakeSpeech() => FakeSpeech._(StreamController<Object?>.broadcast());

  final StreamController<Object?> _events;
  final List<String> calls = [];
  String mic = 'granted';

  void push(String kind, [Map<String, Object?> extra = const {}]) =>
      _events.add({
        'type': 'speech',
        'kind': kind,
        't': 0,
        'onDevice': true,
        ...extra,
      });

  void partial(String text) => push('partial', {'text': text});
  void finalResult(String text) => push('final', {'text': text});

  @override
  Future<String> requestMicrophone() async => mic;
  @override
  Future<void> startListening({required bool continuous}) async =>
      calls.add('start continuous=$continuous');
  @override
  Future<void> stopListening() async => calls.add('stop');
  @override
  Future<void> cancelListening() async => calls.add('cancel');
  @override
  Future<Map<String, Object?>> speechStatus() async => {
    'onDevice': true,
    'language': 'en-US',
    'model': 'installed',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dictation', () {
    late FakeSpeech native;
    late SpeechService speech;
    late Dictation d;
    final ends = <(DictationEnd, String)>[];
    final finals = <String>[];

    setUp(() {
      native = FakeSpeech();
      speech = SpeechService(native);
      ends.clear();
      finals.clear();
      d = Dictation(speech)
        ..onEnd = ((end, text) => ends.add((end, text)))
        ..onFinal = finals.add;
    });

    test('partials replace each other; finals commit', () async {
      expect(await d.start(), isTrue);
      expect(d.phase.value, DictationPhase.listening);
      expect(native.calls, ['start continuous=true']);
      native.partial('hello');
      await pumpEventQueue();
      expect(d.partial.value, 'hello');
      native.partial('hello there');
      await pumpEventQueue();
      expect(d.partial.value, 'hello there');
      expect(d.committed.value, '');
      native.finalResult('Hello there.');
      await pumpEventQueue();
      expect(d.committed.value, 'Hello there.');
      expect(d.partial.value, '');
      native.partial('how are');
      native.finalResult('How are you?');
      await pumpEventQueue();
      expect(d.committed.value, 'Hello there. How are you?');
      expect(finals, ['Hello there.', 'Hello there. How are you?']);
      expect(ends, isEmpty);
    });

    test('stop keeps listening until idle and keeps the last final', () async {
      await d.start();
      native.partial('buy milk');
      await pumpEventQueue();
      await d.finish();
      expect(native.calls.last, 'stop');
      expect(d.phase.value, DictationPhase.finishing);
      // The final of the utterance in progress arrives after stop, and idle
      // right behind it.
      native.finalResult('Buy milk and eggs.');
      native.push('idle');
      await pumpEventQueue();
      expect(d.phase.value, DictationPhase.idle);
      expect(ends, [(DictationEnd.done, 'Buy milk and eggs.')]);
      native.partial('after the session');
      await pumpEventQueue();
      expect(d.partial.value, '');
    });

    test('idle ends the session once and later events are ignored', () async {
      await d.start();
      native.finalResult('One.');
      native.push('idle');
      await pumpEventQueue();
      native.finalResult('Stray.');
      native.push('idle');
      await pumpEventQueue();
      expect(ends, [(DictationEnd.done, 'One.')]);
      expect(d.committed.value, 'One.');
    });

    test('cancel discards immediately and cancels the recognizer', () async {
      await d.start();
      native.finalResult('Keep this?');
      await pumpEventQueue();
      await d.cancel();
      expect(d.phase.value, DictationPhase.idle);
      expect(native.calls.last, 'cancel');
      expect(ends, [(DictationEnd.cancelled, 'Keep this?')]);
      native.finalResult('Late.');
      native.push('idle');
      await pumpEventQueue();
      expect(ends, hasLength(1));
    });

    test('an error while listening ends as failed', () async {
      await d.start();
      native.push('error', {'code': 3});
      await pumpEventQueue();
      expect(ends.single.$1, DictationEnd.failed);
      expect(speech.errorCode, 3);
    });

    test('a denied microphone fails without listening', () async {
      native.mic = 'denied';
      expect(await d.start(), isFalse);
      expect(d.phase.value, DictationPhase.idle);
      expect(ends.single.$1, DictationEnd.failed);
      expect(native.calls, isEmpty);
    });

    test('a final from before this session started is not kept', () async {
      final started = d.start();
      native.finalResult('From voice mode.');
      await started;
      await pumpEventQueue();
      expect(d.committed.value, '');
    });
  });

  group('WaveformDriver', () {
    test('rises fast, falls slowly, and scrolls one bar per 50 ms', () {
      final level = ValueNotifier<double>(10);
      final w = WaveformDriver(level);
      w.advance(0.06);
      final risen = w.envelope;
      expect(risen, greaterThan(0.55));
      level.value = -2;
      w.advance(0.06);
      expect(w.envelope, greaterThan(risen * 0.7));
      for (var i = 0; i < 40; i++) {
        w.advance(0.05);
      }
      expect(w.sample(WaveformDriver.bars - 1), lessThan(w.sample(0)));
      final fresh = WaveformDriver(level)..advance(0.025);
      expect(fresh.phase, closeTo(0.5, 1e-6));
    });
  });

  group('Composer while dictating', () {
    late FakeSpeech native;
    late SpeechService speech;
    late ComposerController controller;

    Future<void> pumpComposer(WidgetTester tester) async {
      native = FakeSpeech();
      speech = SpeechService(native);
      controller = ComposerController();
      await tester.pumpWidget(
        MaterialApp(
          theme: aithraTheme(Brightness.light),
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox()),
                Composer(
                  controller: controller,
                  speech: speech,
                  busy: false,
                  canAttachImages: true,
                  onSend: () {},
                  onStop: () {},
                  onFocus: () {},
                ),
              ],
            ),
          ),
        ),
      );
    }

    Future<void> deliver(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    double composerHeight(WidgetTester tester) =>
        tester.getSize(find.byType(Composer)).height;

    testWidgets('its height never changes while the user speaks', (
      tester,
    ) async {
      await pumpComposer(tester);
      final idle = composerHeight(tester);
      // One row: the 40 dp buttons inside the 6 dp inset, plus the
      // composer's own padding.
      expect(
        tester.getSize(find.byType(DecoratedBox).last).height,
        composerRowHeight,
      );
      await tester.tap(find.byTooltip('Dictate'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(RecordingBar), findsOneWidget);
      final listening = composerHeight(tester);
      // The recording bar has the idle row's height; only the transcript
      // strip above it is added.
      expect(tester.getSize(find.byType(RecordingBar)).height, composerButton);
      final heights = <double>{};
      var said = '';
      for (final word
          in 'one two three four five six seven eight nine ten '
                  'eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen '
                  'nineteen twenty twenty-one twenty-two twenty-three twenty-four'
              .split(' ')) {
        said = said.isEmpty ? word : '$said $word';
        native.partial(said);
        await deliver(tester);
        heights.add(composerHeight(tester));
        if (word.endsWith('ten') || word.endsWith('twenty')) {
          native.finalResult(said);
          said = '';
          await deliver(tester);
          heights.add(composerHeight(tester));
        }
      }
      expect(heights, {listening});
      expect(listening, greaterThan(idle));

      // Done: the last final lands in the field with the caret at its end,
      // and the composer returns to its row.
      await tester.tap(find.byTooltip('Done'));
      await deliver(tester);
      native.finalResult(said);
      native.push('idle');
      await deliver(tester);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(RecordingBar), findsNothing);
      expect(controller.text.text, startsWith('one two'));
      expect(controller.text.text, endsWith('twenty-four'));
      expect(
        controller.text.selection,
        TextSelection.collapsed(offset: controller.text.text.length),
      );
      expect(
        find.byTooltip('Dictate'),
        findsOneWidget,
        reason: 'the mic is no longer lit after Stop',
      );
    });

    testWidgets('cancel restores the text from before dictation', (
      tester,
    ) async {
      await pumpComposer(tester);
      controller.setText('Draft');
      await tester.tap(find.byTooltip('Dictate'));
      await tester.pump();
      native.finalResult('spoken words');
      await deliver(tester);
      expect(controller.text.text, 'Draft spoken words');
      await tester.tap(find.byTooltip('Cancel dictation'));
      await deliver(tester);
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.text.text, 'Draft');
      expect(find.byType(RecordingBar), findsNothing);
      expect(native.calls.last, 'cancel');
    });

    testWidgets('the idle row and the recording bar buttons line up', (
      tester,
    ) async {
      await pumpComposer(tester);
      final attach = tester.getRect(find.byTooltip('Add image'));
      final mic = tester.getRect(find.byTooltip('Dictate'));
      final send = tester.getRect(find.byTooltip('Send'));
      for (final r in [attach, mic, send]) {
        expect(r.size, const Size(composerButton, composerButton));
        expect(r.center.dy, send.center.dy);
      }
      await tester.tap(find.byTooltip('Dictate'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final cancel = tester.getRect(find.byTooltip('Cancel dictation'));
      final done = tester.getRect(find.byTooltip('Done'));
      expect(cancel.size, const Size(composerButton, composerButton));
      expect(done.size, const Size(composerButton, composerButton));
      expect(cancel.center.dy, send.center.dy);
      expect(done.right, send.right);
      expect(cancel.left, attach.left);
    });
  });
}
