import 'dart:async';

import 'package:aithra/src/engine/engine_service.dart';
import 'package:aithra/src/memory/recall_index.dart';
import 'package:aithra/src/models/catalog.dart';
import 'package:aithra/src/models/model_manager.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeNative extends NativeBridge {
  FakeNative._(StreamController<Object?> events)
    : super(channel: const MethodChannel('fake'), events: events.stream);
  factory FakeNative() => FakeNative._(StreamController.broadcast());

  bool embedderOnPhone = false;
  int unindexed = 0;
  final List<int> batches = [];
  final List<String> recallQueries = [];
  List<Map<String, Object?>> recallRows = const [];
  void Function()? onBatch;
  PlatformException? recallError;
  PlatformException? indexError;
  final List<String> searches = [];

  @override
  Future<List<Map<String, Object?>>> listModelFiles() async => [
    if (embedderOnPhone)
      {
        'path': '/models/${embeddingModel.fileName}',
        'name': embeddingModel.fileName,
        'size': embeddingModel.sizeBytes,
      },
  ];

  @override
  Future<List<Map<String, Object?>>> queryDownloads() async => const [];

  @override
  Future<Map<String, Object?>> storageInfo() async => {'freeBytes': 1 << 30};

  @override
  Future<int> dbIndexVectors(String modelPath, int limit) async {
    if (indexError != null) throw indexError!;
    final n = unindexed < limit ? unindexed : limit;
    unindexed -= n;
    batches.add(n);
    onBatch?.call();
    return n;
  }

  @override
  Future<List<Map<String, Object?>>> dbRecall(
    String modelPath,
    String query,
    String? excludeConv,
    int limit,
  ) async {
    recallQueries.add(query);
    if (recallError != null) throw recallError!;
    return recallRows;
  }

  @override
  Future<List<Map<String, Object?>>> dbSearchMessages(
    String modelPath,
    String query,
    int limit,
  ) async {
    searches.add(query);
    return [
      {'convId': 'c9', 'content': 'We booked the\nferry', 'score': 0.6},
    ];
  }

  @override
  Future<({int indexed, int total})> dbVectorStatus() async =>
      (indexed: 10 - unindexed, total: 10);
}

void main() {
  late FakeNative native;
  late ModelManager models;
  late EngineService engine;
  late RecallIndex index;

  setUp(() {
    native = FakeNative();
    models = ModelManager(native);
    engine = EngineService(native);
    index = RecallIndex(native: native, engine: engine, models: models);
  });

  test('recall is off without the embedding model', () async {
    await models.refresh();
    expect(await index.recall('my trip to Oslo', 'c1'), isA<RecallOff>());
    expect(native.recallQueries, isEmpty);
  });

  test('recalled messages come back on one line, clipped', () async {
    native
      ..embedderOnPhone = true
      ..recallRows = [
        {'content': 'Booked the\n\nferry to Oslo ${'x' * 300}', 'score': 0.7},
      ];
    await models.refresh();
    final out = await index.recall('my trip to Oslo', 'c1') as Recalled;
    expect(out.snippets.single, startsWith('Booked the ferry to Oslo'));
    expect(out.snippets.single.length, RecallIndex.maxChars + 1);
  });

  test('the embedding model arriving indexes everything in batches', () async {
    native
      ..embedderOnPhone = true
      ..unindexed = 10;
    await models.refresh();
    await pumpEventQueue();
    expect(native.batches, [4, 4, 2, 0]);
  });

  test('indexing stops when the user needs the engine', () async {
    native
      ..embedderOnPhone = true
      ..unindexed = 10
      ..onBatch = engine.preemptBackground;
    await models.refresh();
    await pumpEventQueue();
    expect(native.batches, [4]);
    expect(native.unindexed, 6);
  });

  test(
    'a recall failure is reported and recall stays off until retried',
    () async {
      native
        ..embedderOnPhone = true
        ..recallError = PlatformException(code: 'embed', message: 'bad model');
      await models.refresh();
      await pumpEventQueue();
      final first = await index.recall('trip', 'c1');
      expect(first, isA<RecallFailed>());
      expect((first as RecallFailed).message, 'bad model');
      expect(index.failure, 'bad model');
      expect(await index.recall('again', 'c1'), isA<RecallFailed>());
      expect(native.recallQueries, ['trip']);
      expect(await index.search('ferry'), isEmpty);
      expect(native.searches, isEmpty);

      native.recallError = null;
      index.retry();
      expect(index.failure, isNull);
      expect(await index.recall('trip', 'c1'), isA<Recalled>());
    },
  );

  test('an indexing failure is reported, not dropped', () async {
    native
      ..embedderOnPhone = true
      ..unindexed = 10
      ..indexError = PlatformException(code: 'embed', message: 'out of memory');
    await models.refresh();
    await pumpEventQueue();
    expect(index.failure, 'out of memory');
  });

  test('downloading the model again clears a failure', () async {
    native
      ..embedderOnPhone = true
      ..indexError = PlatformException(code: 'embed', message: 'corrupt');
    await models.refresh();
    await pumpEventQueue();
    expect(index.failure, 'corrupt');
    native
      ..embedderOnPhone = false
      ..indexError = null;
    await models.refresh();
    native.embedderOnPhone = true;
    await models.refresh();
    expect(index.failure, isNull);
  });

  test('search finds messages by meaning, one line per hit', () async {
    native.embedderOnPhone = true;
    await models.refresh();
    final hits = await index.search('ferry');
    expect(hits.single.convId, 'c9');
    expect(hits.single.snippet, 'We booked the ferry');
  });

  test('progress is readable while indexing', () async {
    native
      ..embedderOnPhone = true
      ..unindexed = 6;
    await models.refresh();
    await pumpEventQueue();
    expect((index.indexed, index.total), (10, 10));
  });
}
