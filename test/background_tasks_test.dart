import 'dart:async';

import 'package:aithra/src/chat/chat_titler.dart';
import 'package:aithra/src/engine/engine_service.dart';
import 'package:aithra/src/memory/memory_curator.dart';
import 'package:aithra/src/models/catalog.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An engine whose generations stream [reply] and finish when [finish] is
/// called; cancelling the running request ends it, as the native engine
/// does.
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
  }) async => {
    'contextSize': 4096,
    'loadMs': 1.0,
    'peakRssMb': 1.0,
    'cacheWrittenMb': 0.0,
  };

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

  void finish({bool cancelled = false}) =>
      _running?.complete({'cancelled': cancelled});

  @override
  Future<void> unload() async {}

  final List<int> cancelledIds = [];

  @override
  Future<void> cancel(int requestId) async {
    cancels++;
    cancelledIds.add(requestId);
    // Like EngineHost: only the request named, and only once it is running.
    if (started.isNotEmpty && started.last == requestId) {
      finish(cancelled: true);
    }
  }
}

ModelSpec get _spec => catalog.first;
BackendOption get _cpu => BackendOption.byId('cpu');

void main() {
  group('memory edits from model output', () {
    const keys = {'m1': 'id-1', 'm2': 'id-2', 'm3': 'id-3'};
    MemoryEdits parse(String raw) => MemoryCurator.parse(raw, keys: keys);

    test('reads adds, updates and removals out of the JSON reply', () {
      final e = parse(
        'Sure!\n```json\n{"add": ["Lives in Oslo"], '
        '"update": [{"id": "m1", "text": "Works as a nurse"}], '
        '"remove": ["m2"]}\n```',
      );
      expect(e.add, ['Lives in Oslo']);
      expect(e.update, {'id-1': 'Works as a nurse'});
      expect(e.remove, ['id-2']);
    });

    test('nothing to change is valid', () {
      expect(parse('{"add": [], "update": [], "remove": []}').isEmpty, isTrue);
      expect(parse('{}').isEmpty, isTrue);
    });

    test('anything but the JSON asked for changes nothing', () {
      expect(parse('The user lives in Oslo.').isEmpty, isTrue);
      expect(parse('{"add": ["Lives in Os').isEmpty, isTrue);
      expect(parse('{"add": "Lives in Oslo"}').isEmpty, isTrue);
      expect(parse('["Lives in Oslo"]').isEmpty, isTrue);
    });

    test('drops non-strings, blanks, overlong notes, control characters '
        'and repeats', () {
      final e = parse(
        '{"add": [1, null, " ", "x", "${'a' * 161}", '
        '"Is vegetarian", "is  vegetarian", "Speaks\\u0007 Urdu"]}',
      );
      expect(e.add, ['Is vegetarian']);
    });

    test('only touches memories it was shown', () {
      final e = parse(
        '{"update": [{"id": "m9", "text": "Hacked"}, {"id": "id-1", '
        '"text": "Raw id"}, {"id": "m3", "text": 5}], '
        '"remove": ["m7", "id-2", 3]}',
      );
      expect(e.isEmpty, isTrue);
    });

    test('a memory is updated or removed, not both, and at most three of '
        'each change', () {
      final e = parse(
        '{"add": ["Aa a", "Bb b", "Cc c", "Dd d"], '
        '"update": [{"id": "m1", "text": "New text"}], '
        '"remove": ["m1", "m2", "m2"]}',
      );
      expect(e.add, hasLength(3));
      expect(e.update.keys, ['id-1']);
      expect(e.remove, ['id-2']);
    });

    test('the prompt shows the related memories by key', () {
      final turns = MemoryCurator.prompt(
        userMessage: 'I moved to Bergen',
        reply: 'Nice!',
        related: const [('m1', 'Lives in Oslo')],
      );
      expect(turns.first.role, 'system');
      expect(turns.last.text, contains('m1: Lives in Oslo'));
      expect(turns.last.text, contains('I moved to Bergen'));
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
      native = FakeEngine()..reply = '{"add": []}';
      engine = EngineService(native);
      await engine.ensureLoaded(_spec, '/m', _cpu);
    });

    test('return the full reply once the engine is free', () async {
      final result = engine.backgroundRun().generate(const [], maxTokens: 8);
      await pumpEventQueue();
      native.finish();
      expect(await result, '{"add": []}');
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
  group('stopping a reply', () {
    late FakeEngine native;
    late EngineService engine;

    setUp(() async {
      native = FakeEngine()..reply = 'hi';
      engine = EngineService(native);
      await engine.ensureLoaded(_spec, '/m', _cpu);
    });

    test('a reply stopped while queued never reaches the engine', () async {
      final first = engine.generate(const [], maxTokens: 8);
      first.text.listen((_) {});
      final second = engine.generate(const [], maxTokens: 8);
      second.text.listen((_) {});
      await pumpEventQueue();
      await second.cancel();
      native.finish();
      await first.done;
      await second.done;
      expect(second.cancelled, isTrue);
      expect(native.started, hasLength(1));
    });

    test('the stop names the request it is for', () async {
      final reply = engine.generate(const [], maxTokens: 8);
      reply.text.listen((_) {});
      await pumpEventQueue();
      await reply.cancel();
      await reply.done;
      expect(native.cancelledIds, [native.started.single]);
      expect(reply.cancelled, isTrue);
    });

    test('a reply that ran to the end is not cancelled', () async {
      final reply = engine.generate(const [], maxTokens: 8);
      reply.text.listen((_) {});
      await pumpEventQueue();
      native.finish();
      await reply.done;
      expect(reply.cancelled, isFalse);
    });
  });
}
