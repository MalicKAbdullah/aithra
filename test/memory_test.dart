import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:aithra/src/data/settings_store.dart';
import 'package:aithra/src/data/vault.dart';
import 'package:aithra/src/engine/engine_service.dart';
import 'package:aithra/src/memory/memory_curator.dart';
import 'package:aithra/src/memory/memory_keeper.dart';
import 'package:aithra/src/memory/memory_store.dart';
import 'package:aithra/src/memory/profile.dart';
import 'package:aithra/src/models/catalog.dart';
import 'package:aithra/src/models/model_manager.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_replies.dart';

class MemVault extends Vault {
  MemVault() : super('/dev/null', Uint8List(32));
  final Map<String, Object?> docs = {};

  @override
  Future<Object?> read(String name) async => docs[name];

  @override
  Future<void> write(String name, Object? value) async =>
      docs[name] = jsonDecode(jsonEncode(value));

  @override
  Future<void> delete(String name) async => docs.remove(name);
}

enum Prompt { gate, rewrite, suggest, tidy }

Prompt kindOf(List<EngineTurn> turns) {
  final system = turns.first.text;
  if (system.contains('should remember in future')) return Prompt.gate;
  if (system.contains('You keep a short profile')) return Prompt.rewrite;
  if (system.contains("Write what the user's words suggest")) {
    return Prompt.suggest;
  }
  if (system.contains('You are sorting notes')) return Prompt.tidy;
  throw StateError('Unknown prompt: $system');
}

/// A loaded model that answers each kind of memory prompt from [answers],
/// and an embedding model whose vectors come from [vectors].
class FakeModel extends NativeBridge with FakeReplies {
  FakeModel._(this._events)
    : super(channel: const MethodChannel('fake'), events: _events.stream);
  factory FakeModel() => FakeModel._(StreamController.broadcast());

  final StreamController<Object?> _events;
  bool embedderOnPhone = false;
  final Map<Prompt, String Function(List<EngineTurn>)> answers = {};
  final List<(Prompt, List<EngineTurn>)> prompts = [];

  /// Runs while the model "thinks", before the answer is returned: the
  /// user's next message preempting, or the user editing memory.
  void Function(Prompt)? whileGenerating;
  final Map<String, List<double>> vectors = {};

  List<Prompt> get kinds => [for (final (k, _) in prompts) k];
  List<EngineTurn> last(Prompt kind) =>
      prompts.lastWhere((p) => p.$1 == kind).$2;

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
    final kind = kindOf(turns);
    prompts.add((kind, turns));
    whileGenerating?.call(kind);
    final answer = answers[kind];
    if (answer == null) throw StateError('No answer set for $kind');
    _events.add({
      'type': 'token',
      'requestId': requestId,
      'text': answer(turns),
    });
    return {'cancelled': false, 'stopped': false};
  }

  @override
  Future<void> cancel(int requestId) async {}

  @override
  Future<List<Float32List>> embed(
    String modelPath,
    List<String> texts, {
    required bool query,
  }) async => [
    for (final t in texts)
      Float32List.fromList(vectors[t] ?? (throw StateError('No vector: $t'))),
  ];

  @override
  Future<List<Map<String, Object?>>> listModelFiles() async => [
    {'path': '/models/${_e2b.fileName}', 'name': _e2b.fileName, 'size': 1},
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
  Future<Map<String, Object?>> storageInfo() async => {'freeBytes': 1 << 34};
}

ModelSpec get _e2b => catalog.firstWhere((m) => m.id == 'gemma4-e2b');

class Harness {
  Harness._(this.model, this.vault, this.engine, this.memories, this.keeper);

  final FakeModel model;
  final MemVault vault;
  final EngineService engine;
  final MemoryStore memories;
  final MemoryKeeper keeper;

  static Future<Harness> start({
    bool embedder = false,
    Map<String, Object?> docs = const {},
  }) async {
    final model = FakeModel()..embedderOnPhone = embedder;
    final vault = MemVault()..docs.addAll(docs);
    final settings = SettingsStore(vault);
    final engine = EngineService(model);
    final models = ModelManager(model, runsLlama: true);
    await models.refresh();
    await engine.ensureLoaded(_e2b, '/models/x', BackendOption.byId('cpu'));
    final memories = MemoryStore(vault);
    await memories.load();
    // Created after the load, so tests start each background pass.
    final keeper = MemoryKeeper(
      native: model,
      engine: engine,
      memories: memories,
      models: models,
      settings: settings,
    );
    return Harness._(model, vault, engine, memories, keeper);
  }

  Future<MemoryUpdate?> learn(String message) =>
      keeper.learn(engine.backgroundRun(), asked: message);

  Future<void> catchUp() => keeper.catchUp(engine.backgroundRun());

  List<String> texts(ProfileSection s) => [
    for (final i in memories.section(s)) i.text,
  ];

  /// Answers the gate with [kind] quoting [quote].
  void gate(String kind, [String quote = '']) =>
      model.answers[Prompt.gate] = (_) =>
          jsonEncode({'keep': kind, 'quote': quote});

  void rewrite(String section, List<String> items) =>
      model.answers[Prompt.rewrite] = (_) =>
          jsonEncode({'section': section, 'items': items});
}

ProfileText profile({
  List<String> about = const [],
  List<String> preferences = const [],
  List<String> work = const [],
  List<String> interests = const [],
  List<String> projects = const [],
}) => {
  ProfileSection.about: about,
  ProfileSection.preferences: preferences,
  ProfileSection.work: work,
  ProfileSection.interests: interests,
  ProfileSection.projects: projects,
};

List<double> unit(List<double> v) {
  final n = math.sqrt(v.fold(0.0, (s, x) => s + x * x));
  return [for (final x in v) x / n];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('gate output', () {
    const message = 'I work as a nurse in Leeds.\nWhat shifts suit a parent?';

    test('reads the kind and the quote', () {
      final v = MemoryGate.parse(
        'Sure! {"keep": "stated", "quote": "I work as a nurse in Leeds."}',
        message,
      )!;
      expect(v.kind, GateKind.stated);
      expect(v.quote, 'I work as a nurse in Leeds.');
      expect(
        MemoryGate.parse('{"keep": "asked", "quote": "nurse"}', message)!.kind,
        GateKind.asked,
      );
    });

    test('"none" and malformed answers keep nothing', () {
      for (final raw in [
        '{"keep": "none"}',
        '{"keep": "none", "quote": "I work as a nurse"}',
        '',
        'The user is a nurse.',
        '{"keep": "stated", "quote": "I work as a nu',
        '["stated", "I work as a nurse"]',
        '{"keep": "maybe", "quote": "I work as a nurse"}',
        '{"keep": "stated"}',
        '{"keep": "stated", "quote": 7}',
        '{"keep": "stated", "quote": "  "}',
        '{"keep": ["stated"], "quote": "I work as a nurse"}',
      ]) {
        expect(MemoryGate.parse(raw, message), isNull, reason: raw);
      }
    });

    test('a quote that is not in the message word for word is rejected', () {
      for (final quote in [
        'Works as a nurse in Leeds',
        'i work as a nurse in leeds',
        'I work as a doctor',
        'The user is a parent',
      ]) {
        expect(
          MemoryGate.parse(
            jsonEncode({'keep': 'stated', 'quote': quote}),
            message,
          ),
          isNull,
          reason: quote,
        );
      }
    });

    test('a quote copied across a line break still counts', () {
      final v = MemoryGate.parse(
        '{"keep": "stated", "quote": "in Leeds. What shifts"}',
        message,
      );
      expect(v?.quote, 'in Leeds. What shifts');
    });

    test('the prompt holds only the user\'s message', () {
      final turns = MemoryGate.prompt('What watch am I wearing?');
      expect(turns, hasLength(2));
      expect(turns.last.text, contains('What watch am I wearing?'));
    });
  });

  group('section rewrite output', () {
    final current = profile(
      about: ['Name is Sam', 'Lives in Oslo', 'Has a daughter', 'Speaks Urdu'],
    );
    SectionRewrite? parse(Object json, [ProfileText? p]) =>
        ProfileRewriter.parse(jsonEncode(json), p ?? current);

    test('updates a line in place', () {
      final r = parse({
        'section': 'about',
        'items': [
          'Name is Sam',
          'Lives in Bergen',
          'Has a daughter',
          'Speaks Urdu',
        ],
      })!;
      expect(r.section, ProfileSection.about);
      expect(r.items[1], 'Lives in Bergen');
    });

    test('rejects anything but one known section of short distinct lines', () {
      for (final json in <Object>[
        {'section': 'hobbies', 'items': <String>[]},
        {'section': 'about', 'items': 'Name is Sam'},
        {'section': 'about'},
        {'items': <String>[]},
        {
          'section': 'about',
          'items': ['Name is Sam', 4],
        },
        {
          'section': 'about',
          'items': ['Name is Sam', 'x'],
        },
        {
          'section': 'about',
          'items': ['Name is Sam', 'a' * 161],
        },
        {
          'section': 'about',
          'items': ['Name is Sam', 'Bell\u0007 rings'],
        },
        {
          'section': 'about',
          'items': ['Name is Sam', 'name is  sam'],
        },
      ]) {
        expect(parse(json), isNull, reason: '$json');
      }
      expect(ProfileRewriter.parse('not json', current), isNull);
      expect(
        ProfileRewriter.parse('{"section": "about", "items": ["Na', current),
        isNull,
      );
    });

    test('adds at most one line', () {
      expect(
        parse({
          'section': 'work',
          'items': ['Nurse', 'Works nights'],
        }),
        isNull,
      );
      expect(
        parse({
          'section': 'work',
          'items': ['Nurse'],
        })?.items,
        ['Nurse'],
      );
    });

    test('changes or drops at most two existing lines', () {
      expect(
        parse({
          'section': 'about',
          'items': [
            'Name is Sam',
            'Lives in Bergen',
            'Has two daughters',
            'Speaks Urdu',
          ],
        }),
        isNotNull,
      );
      expect(
        parse({
          'section': 'about',
          'items': [
            'Name is Alex',
            'Lives in Bergen',
            'Has two daughters',
            'Speaks Urdu',
          ],
        }),
        isNull,
      );
      expect(parse({'section': 'about', 'items': <String>[]}), isNull);
    });

    test('never grows a section past the cap, but keeps one the user grew', () {
      final full = [for (var i = 0; i < 8; i++) 'Line $i'];
      expect(
        parse({
          'section': 'interests',
          'items': [...full, 'Line 8'],
        }, profile(interests: full)),
        isNull,
      );
      final grown = [for (var i = 0; i < 10; i++) 'Line $i'];
      expect(
        parse({
          'section': 'interests',
          'items': [...grown.take(9), 'Line nine, updated'],
        }, profile(interests: grown)),
        isNotNull,
      );
      expect(
        parse({
          'section': 'interests',
          'items': [...grown, 'Line 10'],
        }, profile(interests: grown)),
        isNull,
      );
    });

    test('the prompt shows the whole profile and the words', () {
      final turns = ProfileRewriter.prompt(
        profile: current,
        words: 'We moved to Bergen',
        origin: MemoryOrigin.stated,
      );
      expect(turns.last.text, contains('  - Lives in Oslo'));
      expect(turns.last.text, contains('projects:\n  (empty)'));
      expect(turns.last.text, contains('We moved to Bergen'));
    });
  });

  group('suggestion output', () {
    test('one line in a known section', () {
      expect(
        SuggestionWriter.parse('{"section": "interests", "text": "Hikes"}'),
        (ProfileSection.interests, 'Hikes'),
      );
      expect(
        SuggestionWriter.parse('{"section": "fun", "text": "Hikes"}'),
        isNull,
      );
      expect(
        SuggestionWriter.parse('{"section": "interests", "text": ["Hikes"]}'),
        isNull,
      );
    });
  });

  group('tidy-up output', () {
    const notes = {'n1': 'old1', 'n2': 'old2', 'n3': 'old3'};
    const lines = {'p1': (ProfileSection.about, 'item1')};
    final sizes = {for (final s in ProfileSection.values) s: 0}
      ..[ProfileSection.about] = 1;
    TidyBatch? parse(Object json) => MemoryTidier.parse(
      jsonEncode(json),
      notes: notes,
      lines: lines,
      sizes: sizes,
    );

    test('every note kept, merged or set aside', () {
      final b = parse({
        'keep': [
          {
            'section': 'about',
            'text': 'Name is Sam',
            'from': ['n1', 'p1', 'n3'],
          },
        ],
        'set_aside': [
          {'from': 'n2', 'section': 'interests'},
        ],
      })!;
      expect(b.keep.single.notes, ['old1', 'old3']);
      expect(b.keep.single.absorbs, ['item1']);
      expect(b.setAside.single.note, 'old2');
    });

    test('rejects a note left out, used twice or unknown, a line folded in '
        'twice, a line made only of old lines, and a section past the cap', () {
      Map<String, Object> keep(List<String> from, [String s = 'about']) => {
        'section': s,
        'text': 'Some line',
        'from': from,
      };
      for (final json in <Object>[
        {
          'keep': [
            keep(['n1', 'n2']),
          ],
          'set_aside': <Object>[],
        },
        {
          'keep': [
            keep(['n1', 'n2', 'n3']),
          ],
          'set_aside': [
            {'from': 'n3', 'section': 'about'},
          ],
        },
        {
          'keep': [
            keep(['n1', 'n2', 'n3', 'n4']),
          ],
          'set_aside': <Object>[],
        },
        {
          'keep': [
            keep(['n1', 'p1']),
            keep(['n2', 'n3', 'p1']),
          ],
          'set_aside': <Object>[],
        },
        {
          'keep': [
            keep(['p1']),
            keep(['n1', 'n2', 'n3']),
          ],
          'set_aside': <Object>[],
        },
        {
          'keep': [
            keep(['n1', 'n2', 'n3']),
          ],
          'set_aside': [
            {'from': 'n9', 'section': 'about'},
          ],
        },
        {
          'keep': [
            keep(['n1', 'n2', 'n3'], 'hobbies'),
          ],
          'set_aside': <Object>[],
        },
        {
          'keep': [
            keep(['n1', 'n2', 'n3']),
          ],
        },
      ]) {
        expect(parse(json), isNull, reason: '$json');
      }
      final full = {...sizes}..[ProfileSection.work] = 8;
      expect(
        MemoryTidier.parse(
          jsonEncode({
            'keep': [
              keep(['n1', 'n2', 'n3'], 'work'),
            ],
            'set_aside': <Object>[],
          }),
          notes: notes,
          lines: lines,
          sizes: full,
        ),
        isNull,
      );
    });
  });

  group('learning from a message', () {
    test('a stated fact is filed by rewriting its section, and can be '
        'undone', () async {
      final h = await Harness.start();
      await h.memories.add(ProfileSection.about, 'Lives in Oslo');
      h
        ..gate('stated', 'moved to Bergen')
        ..rewrite('about', ['Lives in Bergen']);
      final update = await h.learn('We moved to Bergen last week');
      expect(h.model.kinds, [Prompt.gate, Prompt.rewrite]);
      expect(
        h.model.last(Prompt.rewrite).last.text,
        contains('moved to Bergen'),
      );
      expect(h.texts(ProfileSection.about), ['Lives in Bergen']);
      expect(
        h.memories.section(ProfileSection.about).single.origin,
        MemoryOrigin.stated,
      );
      expect(await h.memories.undo(update!), isTrue);
      expect(h.texts(ProfileSection.about), ['Lives in Oslo']);
    });

    test('a question about the user ends at the gate', () async {
      final h = await Harness.start();
      h.gate('none');
      expect(await h.learn('What watch am I wearing?'), isNull);
      expect(h.model.kinds, [Prompt.gate]);
      expect(h.memories.count, 0);
    });

    test('a quote the user never wrote ends at the gate', () async {
      final h = await Harness.start();
      h.gate('stated', 'Owns a Rolex');
      expect(await h.learn('What watch am I wearing?'), isNull);
      expect(h.model.kinds, [Prompt.gate]);
    });

    test('a malformed or over-eager rewrite changes nothing', () async {
      final h = await Harness.start();
      for (final t in ['Name is Sam', 'Lives in Oslo', 'Has a cat']) {
        await h.memories.add(ProfileSection.about, t);
      }
      h.gate('stated', 'I live in Bergen');
      for (final answer in [
        '{"section": "about", "items": ["Name is Sam", "Lives in Ber',
        '{"section": "about", "items": ["Name is Alex", "Lives in Bergen", '
            '"Has a dog"]}',
        '{"section": "about", "items": ["Name is Sam", "Lives in Bergen", '
            '"Has a cat", "Likes tea", "Likes jam"]}',
      ]) {
        h.model.answers[Prompt.rewrite] = (_) => answer;
        expect(await h.learn('I live in Bergen now'), isNull);
        expect(h.texts(ProfileSection.about), [
          'Name is Sam',
          'Lives in Oslo',
          'Has a cat',
        ]);
      }
    });

    test('a rewrite of a profile the user changed meanwhile is dropped', () {
      return Future(() async {
        final h = await Harness.start();
        h
          ..gate('stated', 'I am vegan')
          ..rewrite('preferences', ['Is vegan']);
        h.model.whileGenerating = (kind) {
          if (kind == Prompt.rewrite) {
            unawaited(h.memories.add(ProfileSection.preferences, 'Likes tea'));
          }
        };
        expect(await h.learn('I am vegan'), isNull);
        expect(h.texts(ProfileSection.preferences), ['Likes tea']);
      });
    });

    test(
      'the user\'s next message stops the work and nothing changes',
      () async {
        final h = await Harness.start();
        h
          ..gate('stated', 'I am vegan')
          ..rewrite('preferences', ['Is vegan']);
        h.model.whileGenerating = (_) => h.engine.preemptBackground();
        expect(await h.learn('I am vegan'), isNull);
        expect(h.model.kinds, [Prompt.gate]);
        expect(h.memories.count, 0);
      },
    );

    test('memory turned off learns nothing', () async {
      final h = await Harness.start();
      h.vault.docs.clear();
      final settings = SettingsStore(h.vault)..memoryEnabled = false;
      final keeper = MemoryKeeper(
        native: h.model,
        engine: h.engine,
        memories: h.memories,
        models: ModelManager(h.model, runsLlama: true),
        settings: settings,
      );
      expect(
        await keeper.learn(h.engine.backgroundRun(), asked: 'I am vegan'),
        isNull,
      );
      expect(h.model.prompts, isEmpty);
      expect(() => keeper.rememberExplicit('I am vegan'), throwsStateError);
    });
  });

  group('suggestions', () {
    test('a hint becomes a suggestion that stays out of chats, and a '
        'second hint files it', () async {
      final h = await Harness.start();
      h
        ..gate('implied', 'fell walking')
        ..rewrite('interests', ['Enjoys fell walking']);
      h.model.answers[Prompt.suggest] = (_) =>
          '{"section": "interests", "text": "Enjoys fell walking"}';
      expect(await h.learn('Another weekend of fell walking!'), isNull);
      expect(h.memories.suggested.single.text, 'Enjoys fell walking');
      expect(h.memories.count, 0);
      expect((await h.keeper.forPrompt('hello', rank: false)).stable, isEmpty);

      final update = await h.learn('More fell walking this Sunday');
      expect(update, isNotNull);
      expect(h.memories.suggested, isEmpty);
      expect(h.texts(ProfileSection.interests), ['Enjoys fell walking']);
      expect(
        h.memories.section(ProfileSection.interests).single.origin,
        MemoryOrigin.implied,
      );
    });

    test('with the embedding model, a hint worded differently counts as '
        'the same, and one the profile already says is dropped', () async {
      final h = await Harness.start(embedder: true);
      h.model.vectors.addAll({
        'Enjoys hiking': unit([1, 0, 0]),
        'Likes hill walking': unit([0.99, 0.1, 0]),
        'Is vegetarian': unit([0, 1, 0]),
        'Eats no meat': unit([0, 0.98, 0.15]),
      });
      await h.memories.add(ProfileSection.preferences, 'Is vegetarian');
      await h.memories.suggest(ProfileSection.interests, 'Enjoys hiking');
      var note = 'Eats no meat';
      h
        ..gate('implied', 'walk')
        ..rewrite('interests', ['Likes hill walking']);
      h.model.answers[Prompt.suggest] = (_) =>
          jsonEncode({'section': 'interests', 'text': note});
      expect(await h.learn('Off for a walk'), isNull);
      expect(h.memories.suggested.map((s) => s.text), ['Enjoys hiking']);

      note = 'Likes hill walking';
      expect(await h.learn('Off for a walk'), isNotNull);
      expect(h.memories.suggested, isEmpty);
      expect(h.texts(ProfileSection.interests), ['Likes hill walking']);
    });

    test('accepting files it; dismissing drops it', () async {
      final h = await Harness.start();
      await h.memories.suggest(ProfileSection.interests, 'Plays chess');
      await h.memories.suggest(ProfileSection.work, 'Works shifts');
      await h.memories.acceptSuggestion(h.memories.suggested.first.id);
      await h.memories.dismissSuggestion(h.memories.suggested.single.id);
      expect(h.texts(ProfileSection.interests), ['Plays chess']);
      expect(h.memories.suggested, isEmpty);
      expect(h.texts(ProfileSection.work), isEmpty);
    });
  });

  group('remember this', () {
    test('files the message without asking the gate', () async {
      final h = await Harness.start();
      h.rewrite('projects', ['MOT due in May']);
      final r = await h.keeper.rememberExplicit('My MOT is due in May');
      expect(r, isA<Remembered>());
      expect(h.model.kinds, [Prompt.rewrite]);
      expect(
        h.model.last(Prompt.rewrite).last.text,
        contains('asked the assistant to remember'),
      );
      expect(h.texts(ProfileSection.projects), ['MOT due in May']);
      expect(
        h.memories.section(ProfileSection.projects).single.origin,
        MemoryOrigin.asked,
      );
      expect(h.memories.pending, isEmpty);
    });

    test('what the profile already says is reported as known', () async {
      final h = await Harness.start();
      await h.memories.add(ProfileSection.about, 'Name is Sam');
      h.rewrite('about', ['Name is Sam']);
      expect(
        await h.keeper.rememberExplicit('My name is Sam'),
        isA<AlreadyRemembered>(),
      );
      expect(h.memories.pending, isEmpty);
    });

    test('is kept when preempted, and filed in the next idle moment', () async {
      final h = await Harness.start();
      h.rewrite('projects', ['MOT due in May']);
      h.model.whileGenerating = (_) => h.engine.preemptBackground();
      final r = await h.keeper.rememberExplicit('My MOT is due in May');
      expect(r, isA<RememberLater>());
      expect(h.memories.pending.single.text, 'My MOT is due in May');
      expect(h.memories.count, 0);

      // Saved to the vault, so a restart keeps it too.
      final reloaded = MemoryStore(h.vault);
      await reloaded.load();
      expect(reloaded.pending.single.text, 'My MOT is due in May');

      h.model.whileGenerating = null;
      await h.catchUp();
      expect(h.texts(ProfileSection.projects), ['MOT due in May']);
      expect(h.memories.pending, isEmpty);
    });

    test(
      'after two invalid answers it waits for the user to file it',
      () async {
        final h = await Harness.start();
        h.model.answers[Prompt.rewrite] = (_) => '{"section": "nowhere"}';
        await h.keeper.rememberExplicit('My MOT is due in May');
        await h.catchUp();
        expect(h.memories.pending.single.stuck, isTrue);
        final asked = h.model.prompts.length;
        await h.catchUp();
        expect(h.model.prompts, hasLength(asked));

        await h.memories.filePending(
          h.memories.pending.single.id,
          ProfileSection.projects,
          'MOT due in May',
        );
        expect(h.texts(ProfileSection.projects), ['MOT due in May']);
        expect(h.memories.pending, isEmpty);
      },
    );
  });

  group('into a chat', () {
    test('About and Preferences first, then the rest by section, then old '
        'notes not tidied yet', () async {
      final h = await Harness.start(
        docs: {
          'memories': [
            {'id': 'o1', 'text': 'Old note', 'created': 0},
          ],
        },
      );
      await h.memories.add(ProfileSection.projects, 'Building a shed');
      await h.memories.add(ProfileSection.interests, 'Chess');
      await h.memories.add(ProfileSection.preferences, 'Metric units');
      await h.memories.add(ProfileSection.work, 'Nurse');
      await h.memories.add(ProfileSection.about, 'Name is Sam');
      expect((await h.keeper.forPrompt('hi', rank: true)).stable, [
        'Name is Sam',
        'Metric units',
        'Nurse',
        'Chess',
        'Building a shed',
        'Old note',
      ]);
    });

    test('with many lines, picks those closest to the message but keeps '
        'section order', () async {
      final h = await Harness.start(embedder: true);
      await h.memories.add(ProfileSection.about, 'Name is Sam');
      for (var i = 0; i < 12; i++) {
        await h.memories.add(ProfileSection.interests, 'Interest $i');
        h.model.vectors['Interest $i'] = unit([0, 1, 0]);
      }
      await h.memories.add(ProfileSection.work, 'Bakes bread for a living');
      h.model.vectors['Bakes bread for a living'] = unit([1, 0, 0]);
      h.model.vectors['How long to proof dough?'] = unit([1, 0.1, 0]);
      final lines = await h.keeper.forPrompt(
        'How long to proof dough?',
        rank: true,
      );
      // The picks change with each message, so they ride with it and the
      // system prompt keeps only what stays.
      expect(lines.stable, ['Name is Sam']);
      expect(lines.related.first, 'Bakes bread for a living');
      expect(lines.related, hasLength(MemoryKeeper.picked));
    });
  });

  group('tidy-up of older memories', () {
    List<Map<String, Object?>> legacy(int n) => [
      for (var i = 1; i <= n; i++)
        {'id': 'o$i', 'text': 'Old note $i', 'created': i},
    ];

    String sortAll(List<EngineTurn> turns) {
      final keys = RegExp(
        r'^(n\d+): ',
        multiLine: true,
      ).allMatches(turns.last.text).map((m) => m.group(1)!).toList();
      return jsonEncode({
        'keep': [
          {
            'section': 'about',
            'text': 'Name is Sam',
            'from': keys.take(2).toList(),
          },
          for (final k in keys.skip(2).take(keys.length - 3))
            {
              'section': 'interests',
              'text': 'Interest $k',
              'from': [k],
            },
        ],
        'set_aside': [
          {'from': keys.last, 'section': 'work'},
        ],
      });
    }

    test('sorts, merges and sets aside, deleting nothing until the user '
        'confirms', () async {
      final h = await Harness.start(docs: {'memories': legacy(5)});
      expect(h.memories.tidying, isTrue);
      h.model.answers[Prompt.tidy] = sortAll;
      await h.catchUp();
      expect(h.texts(ProfileSection.about), ['Name is Sam']);
      expect(h.texts(ProfileSection.interests), ['Interest n3', 'Interest n4']);
      expect(h.memories.archived.single.text, 'Old note 5');
      final report = h.memories.tidyReport!;
      expect((report.kept, report.merged, report.setAside), (3, 1, 1));
      expect(h.vault.docs['memories'], isNotNull);

      await h.memories.confirmTidy();
      expect(h.vault.docs.containsKey('memories'), isFalse);
      expect(h.memories.tidyReport, isNull);
      expect(h.texts(ProfileSection.about), ['Name is Sam']);
    });

    test('undo puts every old note back as written, in its section', () async {
      final h = await Harness.start(docs: {'memories': legacy(5)});
      await h.memories.add(ProfileSection.work, 'Nurse');
      h.model.answers[Prompt.tidy] = sortAll;
      await h.catchUp();
      await h.memories.undoTidy();
      expect(h.texts(ProfileSection.about), ['Old note 1', 'Old note 2']);
      expect(h.texts(ProfileSection.interests), ['Old note 3', 'Old note 4']);
      expect(h.texts(ProfileSection.work), ['Nurse', 'Old note 5']);
      expect(h.memories.archived, isEmpty);
      expect(h.vault.docs.containsKey('memories'), isFalse);
    });

    test('works in batches of 12, later batches merging into earlier '
        'lines', () async {
      final h = await Harness.start(docs: {'memories': legacy(14)});
      h.model.answers[Prompt.tidy] = (turns) {
        if (!turns.last.text.contains('p1 (about)')) {
          return jsonEncode({
            'keep': [
              {
                'section': 'about',
                'text': 'Name is Sam',
                'from': ['n1', 'n2'],
              },
              {
                'section': 'interests',
                'text': 'Many interests',
                'from': [for (var i = 3; i <= 11; i++) 'n$i'],
              },
            ],
            'set_aside': [
              {'from': 'n12', 'section': 'work'},
            ],
          });
        }
        return jsonEncode({
          'keep': [
            {
              'section': 'about',
              'text': 'Name is Sam Khan',
              'from': ['n1', 'p1'],
            },
          ],
          'set_aside': [
            {'from': 'n2', 'section': 'about'},
          ],
        });
      };
      await h.catchUp();
      expect(h.model.kinds, [Prompt.tidy, Prompt.tidy]);
      expect(h.texts(ProfileSection.about), ['Name is Sam Khan']);
      expect(h.texts(ProfileSection.interests), ['Many interests']);
      final report = h.memories.tidyReport!;
      expect((report.kept, report.merged, report.setAside), (2, 10, 2));
      await h.memories.undoTidy();
      expect(h.texts(ProfileSection.about), [
        'Old note 1',
        'Old note 2',
        'Old note 13',
        'Old note 14',
      ]);
      expect(h.texts(ProfileSection.interests), hasLength(9));
      expect(h.texts(ProfileSection.work), ['Old note 12']);
    });

    test('an answer that loses a note is retried, then the batch is set '
        'aside unsorted, still restorable', () async {
      final h = await Harness.start(docs: {'memories': legacy(3)});
      h.model.answers[Prompt.tidy] = (_) =>
          '{"keep": [{"section": "about", "text": "Name is Sam", '
          '"from": ["n1"]}], "set_aside": []}';
      await h.catchUp();
      expect(h.model.kinds, [Prompt.tidy, Prompt.tidy]);
      expect(h.memories.count, 0);
      expect(h.memories.archived.map((a) => a.text), [
        'Old note 1',
        'Old note 2',
        'Old note 3',
      ]);
      expect(h.memories.archived.every((a) => a.section == null), isTrue);
      await h.memories.restoreArchived(
        h.memories.archived.first.id,
        to: ProfileSection.about,
      );
      expect(h.texts(ProfileSection.about), ['Old note 1']);
    });

    test('preempted, it resumes where it stopped', () async {
      final h = await Harness.start(docs: {'memories': legacy(3)});
      h.model.answers[Prompt.tidy] = sortAll;
      h.model.whileGenerating = (_) => h.engine.preemptBackground();
      await h.catchUp();
      expect(h.memories.tidying, isTrue);
      expect((await h.keeper.forPrompt('hi', rank: false)).stable, [
        'Old note 1',
        'Old note 2',
        'Old note 3',
      ]);
      h.model.whileGenerating = null;
      await h.catchUp();
      expect(h.memories.tidying, isFalse);
    });

    test('the engine loading a model starts the pending work', () async {
      final model = FakeModel();
      final vault = MemVault()..docs['memories'] = legacy(3);
      final engine = EngineService(model);
      final models = ModelManager(model, runsLlama: true);
      await models.refresh();
      final memories = MemoryStore(vault);
      await memories.load();
      MemoryKeeper(
        native: model,
        engine: engine,
        memories: memories,
        models: models,
        settings: SettingsStore(vault),
      );
      model.answers[Prompt.tidy] = sortAll;
      await engine.ensureLoaded(_e2b, '/models/x', BackendOption.byId('cpu'));
      await pumpEventQueue();
      expect(memories.tidying, isFalse);
      expect(memories.tidyReport, isNotNull);
    });
  });

  test('the profile survives a restart', () async {
    final h = await Harness.start();
    await h.memories.add(ProfileSection.about, 'Name is Sam');
    await h.memories.suggest(ProfileSection.interests, 'Plays chess');
    final reloaded = MemoryStore(h.vault);
    await reloaded.load();
    expect(reloaded.section(ProfileSection.about).single.text, 'Name is Sam');
    expect(reloaded.suggested.single.text, 'Plays chess');
  });

  group('gate eval fixture', () {
    final fixture =
        jsonDecode(
              File('test/fixtures/memory_gate_eval.json').readAsStringSync(),
            )
            as Map<String, Object?>;
    final exchanges = [
      for (final e in fixture['exchanges']! as List)
        Map<String, Object?>.from(e as Map),
    ];

    test('about forty labelled exchanges, each quote in its message', () {
      expect(exchanges.length, inInclusiveRange(36, 48));
      final labels = {for (final e in exchanges) e['label']};
      expect(labels, {'none', 'stated', 'asked', 'implied'});
      // Most messages carry nothing to keep; the set must say so too.
      expect(
        exchanges.where((e) => e['label'] == 'none').length,
        greaterThanOrEqualTo(exchanges.length ~/ 3),
      );
      for (final e in exchanges) {
        final message = e['message']! as String;
        if (e['label'] == 'none') continue;
        final quote = e['quote']! as String;
        expect(
          MemoryGate.parse(
            jsonEncode({'keep': e['label'], 'quote': quote}),
            message,
          ),
          isNotNull,
          reason: message,
        );
      }
    });

    test('each label takes the pipeline down its path, and the gate never '
        'sees the reply', () async {
      for (final e in exchanges) {
        final h = await Harness.start();
        final message = e['message']! as String;
        final label = e['label']! as String;
        h
          ..gate(label, (e['quote'] as String?) ?? '')
          ..rewrite('about', ['A fact'])
          ..model.answers[Prompt.suggest] = (_) =>
              '{"section": "interests", "text": "A hint"}';
        await h.learn(message);
        final gate = h.model.last(Prompt.gate);
        expect(
          gate.map((t) => t.text).join(),
          isNot(contains(e['reply']! as String)),
        );
        expect(h.model.kinds, switch (label) {
          'none' => [Prompt.gate],
          'implied' => [Prompt.gate, Prompt.suggest],
          _ => [Prompt.gate, Prompt.rewrite],
        }, reason: message);
        if (label == 'none') expect(h.memories.count, 0);
      }
    });
  });
}
