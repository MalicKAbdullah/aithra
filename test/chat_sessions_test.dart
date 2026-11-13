import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:aithra/src/assistant.dart';
import 'package:aithra/src/calibration/calibration.dart';
import 'package:aithra/src/chat/chat_models.dart';
import 'package:aithra/src/chat/chat_session.dart';
import 'package:aithra/src/chat/chat_sessions.dart';
import 'package:aithra/src/chat/chat_store.dart';
import 'package:aithra/src/chat/reply_queue.dart';
import 'package:aithra/src/data/settings_store.dart';
import 'package:aithra/src/data/vault.dart';
import 'package:aithra/src/engine/engine_service.dart';
import 'package:aithra/src/memory/memory_curator.dart';
import 'package:aithra/src/memory/memory_store.dart';
import 'package:aithra/src/memory/recall_index.dart';
import 'package:aithra/src/models/catalog.dart';
import 'package:aithra/src/models/model_manager.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MemVault extends Vault {
  MemVault() : super('/dev/null', Uint8List(32));
  final Map<String, Object?> docs = {};

  @override
  Future<Object?> read(String name) async => docs[name];

  @override
  Future<void> write(String name, Object? value) async =>
      docs[name] = jsonDecode(jsonEncode(value));
}

/// A store and engine in memory. Chat replies stream only when the test
/// says so ([finish]); background generations (titles, memory) answer at
/// once with [backgroundReply].
class FakeNative extends NativeBridge {
  FakeNative._(this._events)
    : super(channel: const MethodChannel('fake'), events: _events.stream);
  factory FakeNative() => FakeNative._(StreamController.broadcast());

  final StreamController<Object?> _events;
  final conversations = <String, Map<String, Object?>>{};
  final messages = <String, List<Map<String, Object?>>>{};
  var _nextId = 1;

  /// Chat replies started and not yet finished, oldest first.
  final List<(int, List<EngineTurn>, Completer<Map<String, Object?>>)> replies =
      [];
  final List<List<EngineTurn>> background = [];
  String Function(List<EngineTurn>) backgroundReply = (_) => '{}';

  static bool _isChat(List<EngineTurn> turns) =>
      turns.first.role == 'system' &&
      turns.first.text.startsWith('You are Aithra');

  /// Streams [text] as the oldest running reply and ends it.
  void finish(String text, {bool cancelled = false}) {
    final (id, _, done) = replies.removeAt(0);
    _events.add({'type': 'token', 'requestId': id, 'text': text});
    done.complete({'cancelled': cancelled});
  }

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
    if (!_isChat(turns)) {
      background.add(turns);
      _events.add({
        'type': 'token',
        'requestId': requestId,
        'text': backgroundReply(turns),
      });
      return Future.value({'cancelled': false});
    }
    final done = Completer<Map<String, Object?>>();
    replies.add((requestId, turns, done));
    return done.future;
  }

  @override
  Future<void> cancel(int requestId) async {
    final i = replies.indexWhere((r) => r.$1 == requestId);
    if (i < 0) return;
    replies.removeAt(i).$3.complete({'cancelled': true});
  }

  @override
  Future<({List<int>? counts, int? overhead})> countTokens(
    List<EngineTurn> turns,
  ) async => (counts: null, overhead: null);

  @override
  Future<List<Map<String, Object?>>> listModelFiles() async => [
    {
      'path': '/models/${_e2b.fileName}',
      'name': _e2b.fileName,
      'size': _e2b.sizeBytes,
    },
  ];

  @override
  Future<List<Map<String, Object?>>> queryDownloads() async => [];

  @override
  Future<({int indexed, int total})> dbVectorStatus() async =>
      (indexed: 0, total: 0);

  @override
  Future<Map<String, Object?>> storageInfo() async => {'freeBytes': 1 << 34};

  Map<String, Object?> _row(String id) {
    final list = messages[id]!;
    final last = list.isEmpty ? null : list.last;
    return {
      ...conversations[id]!,
      'messageCount': list.length,
      'preview': last?['content'],
      'previewRole': last?['role'],
    };
  }

  @override
  Future<List<Map<String, Object?>>> dbConversations(
    int offset,
    int limit,
  ) async => [
    for (final id in conversations.keys.toList().reversed) _row(id),
  ].skip(offset).take(limit).toList();

  @override
  Future<Map<String, Object?>?> dbConversation(String id) async =>
      conversations.containsKey(id) ? _row(id) : null;

  @override
  Future<void> dbCreateConversation(String id, String title, int now) async {
    conversations[id] = {
      'id': id,
      'title': title,
      'created': now,
      'updated': now,
      'pinned': false,
      'summary': null,
      'summarizedUpto': 0,
      'draft': null,
      'scroll': 0.0,
    };
    messages[id] = [];
  }

  @override
  Future<void> dbUpdateConversation(
    String id,
    Map<String, Object?> fields,
  ) async => conversations[id]?.addAll(fields);

  @override
  Future<void> dbDeleteConversation(String id) async {
    conversations.remove(id);
    messages.remove(id);
  }

  @override
  Future<Map<String, Object?>> dbAddMessage({
    required String convId,
    required String role,
    required String content,
    required List<String> images,
    required String? stats,
    required int now,
  }) async {
    final list = messages[convId];
    if (list == null) throw StateError('No chat $convId');
    final seq = list.isEmpty
        ? 0
        : list.map((m) => m['seq']! as int).reduce(math.max) + 1;
    final id = _nextId++;
    list.add({
      'id': id,
      'seq': seq,
      'role': role,
      'content': content,
      'images': images,
      'created': now,
      'stats': stats,
    });
    return {'id': id, 'seq': seq};
  }

  @override
  Future<List<Map<String, Object?>>> dbMessages(
    String convId,
    int beforeSeq,
    int limit,
  ) async => [
    for (final m in (messages[convId] ?? const []).reversed)
      if ((m['seq']! as int) < beforeSeq) Map.of(m),
  ].take(limit).toList();

  @override
  Future<List<Map<String, Object?>>> dbMessageRange(
    String convId,
    int fromSeq,
    int toSeq,
  ) async => [
    for (final m in messages[convId] ?? const [])
      if ((m['seq']! as int) >= fromSeq && (m['seq']! as int) < toSeq)
        Map.of(m),
  ];

  @override
  Future<void> dbSetTokens(Map<int, int> counts, String model) async {}

  @override
  Future<List<Map<String, Object?>>> dbSearch(String query, int limit) async =>
      [
        for (final id in conversations.keys)
          if ((conversations[id]!['title']! as String).toLowerCase().contains(
            query.toLowerCase(),
          ))
            _row(id),
      ];

  @override
  Future<List<Map<String, Object?>>> dbSearchText(
    String query,
    int limit,
  ) async => [
    for (final id in conversations.keys)
      for (final m in messages[id]!.reversed.take(1))
        if ((m['content']! as String).toLowerCase().contains(
          query.toLowerCase(),
        ))
          {..._row(id), 'snippet': m['content']},
  ];
}

ModelSpec get _e2b => catalog.firstWhere((m) => m.id == 'gemma4-e2b');

class Harness {
  Harness._(this.native, this.sessions, this.store, this.memories);

  final FakeNative native;
  final ChatSessions sessions;
  final ChatStore store;
  final MemoryStore memories;

  static Future<Harness> start() async {
    final native = FakeNative();
    final vault = MemVault();
    final settings = SettingsStore(vault)
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
    final recall = RecallIndex(native: native, engine: engine, models: models);
    final memories = MemoryStore(vault);
    final store = ChatStore(native, searchMessages: recall.search);
    final assistant = Assistant(
      engine: engine,
      models: models,
      settings: settings,
    );
    final keeper = MemoryKeeper(
      native: native,
      memories: memories,
      models: models,
      settings: settings,
    );
    final queue = ReplyQueue();
    final sessions = ChatSessions(
      store: store,
      create: (c) => ChatSession(
        native: native,
        assistant: assistant,
        store: store,
        memories: memories,
        keeper: keeper,
        recall: recall,
        queue: queue,
        conversation: c,
      ),
    );
    return Harness._(native, sessions, store, memories);
  }

  /// Lets every pending future and microtask run.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
  }

  List<String> contents(String convId) => [
    for (final m in native.messages[convId]!) m['content']! as String,
  ];

  Future<ConversationInfo> info(String convId) async =>
      ConversationInfo.fromMap((await native.dbConversation(convId))!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reply queue', () {
    test('grants the engine in order and skips withdrawn replies', () async {
      final q = ReplyQueue();
      final order = <String>[];
      expect(await q.acquire('a'), isTrue);
      final b = q.acquire('b').then((ok) => order.add('b $ok'));
      final c = q.acquire('c').then((ok) => order.add('c $ok'));
      final d = q.acquire('d').then((ok) => order.add('d $ok'));
      q.withdraw('c');
      await pumpEventQueue();
      expect(order, ['c false']);
      q.release('a');
      await b;
      q.release('b');
      await Future.wait([c, d]);
      expect(order, ['c false', 'b true', 'd true']);
      expect(q.busy, isTrue);
      q.release('d');
      expect(q.busy, isFalse);
    });
  });

  group('generation continuity', () {
    test('a reply keeps going and is saved to its own chat after the user '
        'starts another', () async {
      final h = await Harness.start();
      final a = h.sessions.current;
      unawaited(a.send('Explain tides', const []));
      await h.settle();
      expect(h.native.replies, hasLength(1));
      final aId = a.conversation!.id;

      h.sessions.startNew();
      expect(h.sessions.current, isNot(same(a)));
      expect(h.sessions.replying(aId), isTrue);
      expect(a.phase, ReplyPhase.preparing);

      h.native.finish('The moon pulls the sea.');
      await h.settle();
      expect(h.contents(aId), ['Explain tides', 'The moon pulls the sea.']);
      expect(h.sessions.replying(aId), isFalse);
    });

    test('coming back to a chat that is still replying shows the same '
        'session, still streaming', () async {
      final h = await Harness.start();
      final a = h.sessions.current;
      unawaited(a.send('Write a poem', const []));
      await h.settle();
      final aInfo = await h.info(a.conversation!.id);

      h.sessions.startNew();
      h.sessions.open(aInfo);
      expect(h.sessions.current, same(a));
      expect(a.busy, isTrue);
      h.native.finish('Roses.');
      await h.settle();
      expect(a.messages.first.content, 'Roses.');
    });

    test('a message sent in another chat waits its turn, shows as queued, '
        'and starts when the first reply ends', () async {
      final h = await Harness.start();
      final a = h.sessions.current;
      unawaited(a.send('First question', const []));
      await h.settle();

      h.sessions.startNew();
      final b = h.sessions.current;
      unawaited(b.send('Second question', const []));
      await h.settle();
      final bId = b.conversation!.id;
      expect(b.phase, ReplyPhase.queued);
      expect(h.sessions.queued(bId), isTrue);
      expect(h.native.replies, hasLength(1));

      h.native.finish('First answer.');
      await h.settle();
      expect(b.phase, isNot(ReplyPhase.queued));
      expect(h.native.replies, hasLength(1));
      expect(h.native.replies.single.$2.last.text, 'Second question');

      h.native.finish('Second answer.');
      await h.settle();
      expect(h.contents(a.conversation!.id).last, 'First answer.');
      expect(h.contents(bId).last, 'Second answer.');
    });

    test('Stop on a queued reply takes it out of the line; Stop on the '
        'running one leaves the queued one alone', () async {
      final h = await Harness.start();
      final a = h.sessions.current;
      unawaited(a.send('One', const []));
      await h.settle();
      h.sessions.startNew();
      final b = h.sessions.current;
      unawaited(b.send('Two', const []));
      await h.settle();

      await b.stop();
      await h.settle();
      expect(b.busy, isFalse);
      expect(a.busy, isTrue);
      h.native.finish('Answer one.');
      await h.settle();
      expect(h.native.replies, isEmpty);

      unawaited(b.retry());
      await h.settle();
      h.sessions.startNew();
      final c = h.sessions.current;
      unawaited(c.send('Three', const []));
      await h.settle();
      expect(c.phase, ReplyPhase.queued);
      await b.stop();
      await h.settle();
      expect(c.phase, isNot(ReplyPhase.queued));
      expect(h.native.replies.single.$2.last.text, 'Three');
    });

    test('deleting a chat that is replying stops it and leaves nothing '
        'behind', () async {
      final h = await Harness.start();
      final a = h.sessions.current;
      unawaited(a.send('Doomed', const []));
      await h.settle();
      final aId = a.conversation!.id;

      await h.sessions.delete(aId);
      await h.settle();
      expect(h.native.conversations, isNot(contains(aId)));
      expect(h.native.messages, isNot(contains(aId)));
      expect(h.sessions.current.conversation, isNull);
      expect(h.sessions.replying(aId), isFalse);
    });

    test('an empty new chat is not stored until its first message', () async {
      final h = await Harness.start();
      h.sessions.startNew();
      h.sessions.startNew();
      expect(h.native.conversations, isEmpty);
      unawaited(h.sessions.current.send('Hi', const []));
      await h.settle();
      expect(h.native.conversations, hasLength(1));
    });
  });

  group('autonomous memory', () {
    test('the model adds what it judges worth keeping, with a quiet hint '
        'on the reply', () async {
      final h = await Harness.start();
      h.native.backgroundReply = (turns) =>
          turns.first.text.contains('long-term memory')
          ? '{"add": ["Lives in Bergen"], "update": [], "remove": []}'
          : '{"title": "Moving"}';
      final a = h.sessions.current;
      unawaited(a.send('I just moved to Bergen', const []));
      await h.settle();
      h.native.finish('Welcome to Bergen!');
      await h.settle();
      expect(h.memories.items.map((m) => m.text), ['Lives in Bergen']);
      expect(a.memoryUpdates, contains(a.messages.first.seq));
    });

    test('a contradicted memory is updated in place, an exact repeat is '
        'not added again', () async {
      final h = await Harness.start();
      await h.memories.add('Lives in Oslo');
      h.native.backgroundReply = (turns) =>
          turns.first.text.contains('long-term memory')
          ? '{"add": ["lives in oslo"], '
                '"update": [{"id": "m1", "text": "Lives in Bergen"}]}'
          : '{}';
      unawaited(h.sessions.current.send('We left Oslo for Bergen', const []));
      await h.settle();
      h.native.finish('Exciting!');
      await h.settle();
      expect(
        h.native.background
            .where((t) => t.first.text.contains('long-term memory'))
            .single
            .last
            .text,
        contains('m1: Lives in Oslo'),
      );
      expect(h.memories.items.map((m) => m.text), ['Lives in Bergen']);
    });

    test('nothing worth keeping changes nothing and shows no hint', () async {
      final h = await Harness.start();
      h.native.backgroundReply = (_) => '{"add": [], "update": []}';
      final a = h.sessions.current;
      unawaited(a.send('What is 2 + 2?', const []));
      await h.settle();
      h.native.finish('4');
      await h.settle();
      expect(h.memories.items, isEmpty);
      expect(a.memoryUpdates, isEmpty);
    });
  });

  group('drawer search', () {
    test('finds chats by title and by message text, with the matching '
        'message for text hits', () async {
      final h = await Harness.start();
      await h.native.dbCreateConversation('t', 'Harbour trip', 1);
      await h.native.dbCreateConversation('m', 'Groceries', 2);
      await h.native.dbAddMessage(
        convId: 'm',
        role: 'user',
        content: 'Buy fish at the harbour market',
        images: const [],
        stats: null,
        now: 2,
      );
      await h.store.refresh();
      h.store.search('harbour');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await h.settle();
      expect(h.store.items.map((c) => c.id), ['t', 'm']);
      expect(h.store.snippets, {'m': 'Buy fish at the harbour market'});
      h.store.search('');
      expect(h.store.searching, isFalse);
      expect(h.store.items.map((c) => c.id), ['m', 't']);
    });

    test('chats are grouped Pinned, Today, Yesterday, Previous 7 days, '
        'Older', () {
      final now = DateTime(2026, 11, 14, 10);
      ConversationInfo at(DateTime t, {bool pinned = false}) =>
          ConversationInfo.fromMap({
            'id': '$t',
            'title': 'x',
            'created': t.millisecondsSinceEpoch,
            'updated': t.millisecondsSinceEpoch,
            'pinned': pinned,
            'summarizedUpto': 0,
            'scroll': 0.0,
            'messageCount': 0,
          });
      expect(ChatGroup.of(at(DateTime(2026, 11, 14, 9)), now), ChatGroup.today);
      expect(
        ChatGroup.of(at(DateTime(2026, 11, 13, 23)), now),
        ChatGroup.yesterday,
      );
      expect(ChatGroup.of(at(DateTime(2026, 11, 8)), now), ChatGroup.week);
      expect(ChatGroup.of(at(DateTime(2026, 11, 1)), now), ChatGroup.older);
      expect(
        ChatGroup.of(at(DateTime(2025), pinned: true), now),
        ChatGroup.pinned,
      );
    });
  });
}
