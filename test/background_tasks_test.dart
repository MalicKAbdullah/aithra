import 'dart:async';

import 'package:aithra/src/chat/chat_titler.dart';
import 'package:aithra/src/engine/engine_service.dart';
import 'package:aithra/src/memory/fact_suggester.dart';
import 'package:aithra/src/models/catalog.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An engine whose generations stream [reply] and finish when [finish] is
/// called; cancel ends the running one, as the native engine does.
class FakeEngine extends NativeBridge {
  FakeEngine._(this._events)
    : super(channel: const MethodChannel('fake'), events: _events.stream);
  factory FakeEngine() => FakeEngine._(StreamController.broadcast());

  final StreamController<Object?> _events;
  String reply = '';
  int cancels = 0;
  final List<int> started = [];
  Completer<Map<String, Object?>>? _running;

  @override
  Future<Map<String, Object?>> load({
    required String runtime,
    required String path,
    required String backend,
    required int? threads,
    required bool vision,
    required int? maxTokens,
  }) async => {'contextSize': 4096, 'loadMs': 1.0, 'peakRssMb': 1.0};

  @override
  Future<Map<String, Object?>> generate({
    required int requestId,
    required List<EngineTurn> turns,
    required int maxTokens,
    required double temperature,
    required bool ignoreEos,
  }) {
    started.add(requestId);
    _events.add({'type': 'token', 'requestId': requestId, 'text': reply});
    return (_running = Completer()).future;
  }

  void finish() => _running?.complete(const {});

  @override
  Future<void> unload() async {}

  @override
  Future<void> cancel() async {
    cancels++;
    finish();
  }
}

ModelSpec get _spec => catalog.first;
BackendOption get _cpu => BackendOption.byId('cpu');

void main() {
  group('memory suggestions from model output', () {
    test('reads the facts out of the JSON reply', () {
      expect(
        FactSuggester.parse(
          'Sure!\n```json\n{"facts": ["Lives in Oslo", "Has a dog named Rex"]}\n```',
        ),
        ['Lives in Oslo', 'Has a dog named Rex'],
      );
    });

    test('anything but the JSON asked for gives no suggestions', () {
      expect(FactSuggester.parse('The user lives in Oslo.'), isEmpty);
      expect(FactSuggester.parse('{"facts": ["Lives in Os'), isEmpty);
      expect(FactSuggester.parse('{"facts": "Lives in Oslo"}'), isEmpty);
      expect(FactSuggester.parse('[]'), isEmpty);
    });

    test('drops non-strings, blanks, overlong facts and duplicates', () {
      expect(
        FactSuggester.parse(
          '{"facts": [1, null, " ", "x", "${'a' * 121}", '
          '"Is vegetarian", "is  vegetarian", "Speaks\\u0007 Urdu"]}',
        ),
        ['Is vegetarian'],
      );
    });

    test('offers at most three', () {
      expect(
        FactSuggester.parse('{"facts": ["Aa a", "Bb b", "Cc c", "Dd d"]}'),
        hasLength(3),
      );
    });
  });

  group('chat titles from model output', () {
    test('accepts a short title and collapses whitespace', () {
      expect(
        ChatTitler.parse('{"title": " Packing  for the Lakes "}'),
        'Packing for the Lakes',
      );
    });

    test('rejects missing, empty or overlong titles', () {
      expect(ChatTitler.parse('Packing for the Lakes'), isNull);
      expect(ChatTitler.parse('{"title": ""}'), isNull);
      expect(
        ChatTitler.parse('{"title": "one two three four five six seven"}'),
        isNull,
      );
    });
  });

  group('background generations', () {
    late FakeEngine native;
    late EngineService engine;

    setUp(() async {
      native = FakeEngine()..reply = '{"facts": []}';
      engine = EngineService(native);
      await engine.ensureLoaded(_spec, '/m', _cpu);
    });

    test('return the full reply once the engine is free', () async {
      final result = engine.backgroundRun().generate(const [], maxTokens: 8);
      await pumpEventQueue();
      native.finish();
      expect(await result, '{"facts": []}');
    });

    test('never load a model themselves', () async {
      await engine.release();
      expect(
        await engine.backgroundRun().generate(const [], maxTokens: 8),
        isNull,
      );
      expect(native.started, isEmpty);
    });

    test('a running one is cancelled when the user sends', () async {
      final background = engine.backgroundRun().generate(
        const [],
        maxTokens: 8,
      );
      await pumpEventQueue();
      expect(native.started, hasLength(1));
      final reply = engine.generate(const [], maxTokens: 8);
      reply.text.listen((_) {});
      expect(await background, isNull);
      expect(native.cancels, 1);
      await pumpEventQueue();
      expect(native.started, hasLength(2));
      native.finish();
      await reply.done;
    });

    test('a queued one is dropped without running', () async {
      final first = engine.generate(const [], maxTokens: 8);
      first.text.listen((_) {});
      final background = engine.backgroundRun().generate(
        const [],
        maxTokens: 8,
      );
      engine.preemptBackground();
      await pumpEventQueue();
      native.finish();
      await first.done;
      expect(await background, isNull);
      expect(native.started, hasLength(1));
    });

    test('one preemption ends every later step of the run', () async {
      final run = engine.backgroundRun();
      final first = run.generate(const [], maxTokens: 8);
      await pumpEventQueue();
      native.finish();
      expect(await first, isNotNull);
      final reply = engine.generate(const [], maxTokens: 8);
      reply.text.listen((_) {});
      await pumpEventQueue();
      native.finish();
      await reply.done;
      expect(await run.generate(const [], maxTokens: 8), isNull);
      expect(await run.step(() async => 1), isNull);
      expect(native.started, hasLength(2));
    });
  });
}
