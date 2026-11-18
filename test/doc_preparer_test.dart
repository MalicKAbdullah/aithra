import 'dart:async';
import 'dart:convert';

import 'package:aithra/src/assistant.dart';
import 'package:aithra/src/calibration/calibration.dart';
import 'package:aithra/src/data/settings_store.dart';
import 'package:aithra/src/data/vault.dart';
import 'package:aithra/src/docs/doc_preparer.dart';
import 'package:aithra/src/docs/documents.dart';
import 'package:aithra/src/engine/engine_service.dart';
import 'package:aithra/src/models/catalog.dart';
import 'package:aithra/src/models/model_manager.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_replies.dart';

ModelSpec get _e2b => catalog.firstWhere((m) => m.id == 'gemma4-e2b');

class MemVault extends Vault {
  MemVault() : super('/dev/null', Uint8List(32));
  final Map<String, Object?> docs = {};

  @override
  Future<Object?> read(String name) async => docs[name];

  @override
  Future<void> write(String name, Object? value) async =>
      docs[name] = jsonDecode(jsonEncode(value));
}

/// One document with scanned pages and passages, a vision model that reads
/// a page per background generation, and an embedder that embeds a batch
/// per step.
class FakeDocNative extends NativeBridge with FakeReplies {
  FakeDocNative._(this._events)
    : super(channel: const MethodChannel('fake'), events: _events.stream);
  factory FakeDocNative() => FakeDocNative._(StreamController.broadcast());

  final StreamController<Object?> _events;

  /// Scanned pages not read yet.
  final List<int> unread = [1, 2];
  final Map<int, String> read = {};
  int passages = 20;
  int indexed = 0;
  final List<int> generations = [];

  void setVisible(bool visible) =>
      _events.add({'type': 'visibility', 'visible': visible});

  @override
  Future<List<Map<String, Object?>>> listModelFiles() async => [
    for (final m in [_e2b, embeddingModel])
      {
        'path': '/models/${m.fileName}',
        'name': m.fileName,
        'size': m.sizeBytes,
      },
  ];

  @override
  Future<List<Map<String, Object?>>> queryDownloads() async => [];

  @override
  Future<Map<String, Object?>> storageInfo() async => {'freeBytes': 1 << 34};

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
    bool keepContext = false,
    bool background = false,
  }) async {
    generations.add(requestId);
    _events.add({
      'type': 'token',
      'requestId': requestId,
      'text': 'Text of a page',
    });
    return {'cancelled': false};
  }

  @override
  Future<List<Map<String, Object?>>> unreadPages(String id) async => [
    if (!deleted.contains(id))
      for (final p in unread) {'page': p, 'image': 'img-$p'},
  ];

  /// Documents the user deletes the moment their page list is read.
  final Set<String> deleteOnRead = {};
  final Set<String> deleted = {};

  /// Documents whose indexing fails with an error nobody expects.
  final Set<String> broken = {};

  @override
  Future<Uint8List?> dbImage(String id, {required bool thumb}) async {
    if (deleteOnRead.isNotEmpty) {
      deleted.addAll(deleteOnRead);
      return null;
    }
    return Uint8List(4);
  }

  @override
  Future<void> setPageText(String id, int page, String text) async {
    unread.remove(page);
    read[page] = text;
    passages += 2;
  }

  @override
  Future<({int embedded, int indexed, int total})> indexDocument(
    String modelPath,
    String id,
    int limit,
  ) async {
    if (broken.contains(id)) throw ArgumentError('broken index');
    if (deleted.contains(id)) return (embedded: 0, indexed: 0, total: 0);
    final n = (passages - indexed).clamp(0, limit);
    indexed += n;
    return (embedded: n, indexed: indexed, total: passages);
  }
}

DocInfo _doc({String id = 'd1', int unreadPages = 2}) => DocInfo(
  id: id,
  name: 'scan.pdf',
  mime: 'application/pdf',
  pages: 2,
  paged: true,
  chars: 0,
  unreadPages: unreadPages,
);

Future<(FakeDocNative, DocPreparer)> _start() async {
  final native = FakeDocNative();
  final settings = SettingsStore(MemVault())
    ..onboarded = true
    ..selectedModelId = _e2b.id
    ..calibrations[_e2b.id] = Calibration(
      modelId: _e2b.id,
      fileSize: _e2b.sizeBytes,
      chosenBackend: 'cpu',
      finishedAt: DateTime(2026),
      results: const [],
    );
  final engine = EngineService(native);
  final models = ModelManager(native, runsLlama: true);
  await models.refresh();
  final assistant = Assistant(
    engine: engine,
    models: models,
    settings: settings,
  );
  return (native, DocPreparer(native: native, assistant: assistant));
}

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await pumpEventQueue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reads the scanned pages, then embeds every passage, as soon as the '
      'document is attached', () async {
    final (native, preparer) = await _start();
    preparer.prepare(_doc());
    expect(preparer.progress['d1']?.stage, PrepStage.reading);
    await _settle();
    expect(native.read.keys, [1, 2]);
    expect(native.indexed, native.passages);
    expect(preparer.progress, isEmpty);
  });

  test(
    'waits while Aithra is off screen and carries on once it is back',
    () async {
      final (native, preparer) = await _start();
      native.setVisible(false);
      await _settle();
      preparer.prepare(_doc());
      await _settle();
      expect(native.generations, isEmpty);
      expect(native.indexed, 0);
      native.setVisible(true);
      await _settle();
      expect(native.read.keys, [1, 2]);
      expect(native.indexed, native.passages);
    },
  );

  test('a removed document is not prepared further', () async {
    final (native, preparer) = await _start();
    native.setVisible(false);
    await _settle();
    preparer.prepare(_doc());
    preparer.drop('d1');
    native.setVisible(true);
    await _settle();
    expect(native.generations, isEmpty);
    expect(native.indexed, 0);
    expect(preparer.progress, isEmpty);
  });

  test('a document deleted while its pages are read ends cleanly, and the '
      'next one is prepared', () async {
    final (native, preparer) = await _start();
    native.deleteOnRead.add('d1');
    preparer.prepare(_doc());
    await _settle();
    expect(native.generations, isEmpty);
    expect(preparer.progress, isEmpty);
    expect(preparer.failures, isEmpty);
    native.deleteOnRead.clear();
    preparer.prepare(_doc(id: 'd2', unreadPages: 0));
    await _settle();
    expect(native.indexed, native.passages);
    expect(preparer.progress, isEmpty);
  });

  test("one document's unexpected failure is reported and leaves the "
      'others to be prepared', () async {
    final (native, preparer) = await _start();
    native.broken.add('d1');
    final errors = <Object>[];
    await runZonedGuarded(() async {
      preparer.prepare(_doc(unreadPages: 0));
      preparer.prepare(_doc(id: 'd2', unreadPages: 0));
      await _settle();
    }, (e, _) => errors.add(e));
    expect(errors.single, isA<ArgumentError>());
    expect(native.indexed, native.passages);
    expect(preparer.progress, isEmpty);
  });

  test('labels progress for the file chip', () {
    expect(
      prepLabel((stage: PrepStage.reading, done: 3, total: 5)),
      'Reading · 60%',
    );
    expect(
      prepLabel((stage: PrepStage.indexing, done: 1, total: 4)),
      'Indexing · 25%',
    );
  });
}
