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
    return recallRows;
  }
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
    expect(await index.recall('my trip to Oslo', 'c1'), isEmpty);
    expect(native.recallQueries, isEmpty);
  });

  test('recalled messages come back on one line, clipped', () async {
    native
      ..embedderOnPhone = true
      ..recallRows = [
        {'content': 'Booked the\n\nferry to Oslo ${'x' * 300}', 'score': 0.7},
      ];
    await models.refresh();
    final out = await index.recall('my trip to Oslo', 'c1');
    expect(out.single, startsWith('Booked the ferry to Oslo'));
    expect(out.single.length, RecallIndex.maxChars + 1);
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
}
