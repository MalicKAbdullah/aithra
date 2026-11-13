import 'dart:typed_data';

import '../data/settings_store.dart';
import '../engine/engine_service.dart';
import '../model_output.dart';
import '../models/catalog.dart';
import '../models/model_manager.dart';
import '../platform/native.dart';
import 'memory_store.dart';

/// Changes to long-term memory that the model asked for, validated.
class MemoryEdits {
  const MemoryEdits({
    this.add = const [],
    this.update = const {},
    this.remove = const [],
  });

  /// New memories.
  final List<String> add;

  /// New text for existing memories, by memory id.
  final Map<String, String> update;

  /// Ids of memories that are wrong or out of date.
  final List<String> remove;

  bool get isEmpty => add.isEmpty && update.isEmpty && remove.isEmpty;
}

/// The hidden instruction that lets the model decide, after a reply, what
/// about the user is worth remembering for future chats, and the validation
/// of its answer. The model does all the judging, in whatever language the
/// user writes; this file only builds the prompt and treats the reply as
/// untrusted data.
abstract final class MemoryCurator {
  static const int maxTokens = 192;
  static const int maxEach = 3;
  static const int minChars = 3;
  static const int maxChars = 160;

  /// The user's message and the reply are cut to these many characters.
  static const int maxMessageChars = 1500;
  static const int maxReplyChars = 400;

  static const String _instruction =
      "You maintain the assistant's long-term memory of the user: a short "
      'list of notes shown to the assistant in future, unrelated '
      'conversations.\n'
      'Decide whether the exchange reveals something worth keeping for the '
      'long term: durable facts about the user (name, family, home, work, '
      'studies), lasting preferences, ongoing goals and projects, or context '
      'they would expect the assistant to know next time. Most exchanges '
      'reveal nothing like that; then change nothing.\n'
      'Do not keep: the questions or requests themselves, one-off tasks, '
      'passing moods, general knowledge, what the assistant said, or '
      'sensitive details (health, money, beliefs) unless the user clearly '
      'wants them remembered.\n'
      "When the user's message makes an existing note wrong or out of date, "
      'update or remove that note instead of adding one that conflicts with '
      'it. Never add what an existing note already says.\n'
      'Write each note as one short sentence in the third person, such as '
      '"Lives in Oslo", in the language of the user\'s message.\n'
      'Reply with JSON only, in the form {"add": ["..."], "update": '
      '[{"id": "m1", "text": "..."}], "remove": ["m2"]}, with empty lists '
      'when nothing should change.';

  /// [related] pairs each note's prompt key ("m1") with its text.
  static List<EngineTurn> prompt({
    required String userMessage,
    required String reply,
    required List<(String, String)> related,
  }) {
    final notes = related.isEmpty
        ? '(none)'
        : [for (final (key, text) in related) '$key: $text'].join('\n');
    return [
      const EngineTurn('system', _instruction),
      EngineTurn(
        'user',
        'Existing notes that may be related:\n$notes\n\n'
            'User:\n"""\n'
            '${clipChars(userMessage.trim(), maxMessageChars)}\n"""\n\n'
            'Assistant (context only):\n"""\n'
            '${clipChars(reply.trim(), maxReplyChars)}\n"""',
      ),
    ];
  }

  /// The edits in a model reply. [keys] maps the prompt keys of the notes
  /// shown to their memory ids; an edit naming any other key is dropped.
  /// Anything that is not the JSON asked for gives no edits.
  static MemoryEdits parse(String raw, {required Map<String, String> keys}) {
    final json = jsonObjectIn(raw);
    if (json == null) return const MemoryEdits();

    String? note(Object? v) {
      if (v is! String) return null;
      final line = oneLine(v);
      if (line == null || line.length < minChars || line.length > maxChars) {
        return null;
      }
      return line;
    }

    final add = <String>[];
    final seen = <String>{};
    if (json['add'] case final List<Object?> list) {
      for (final v in list) {
        final text = note(v);
        if (text != null && seen.add(text.toLowerCase())) add.add(text);
        if (add.length == maxEach) break;
      }
    }

    final update = <String, String>{};
    if (json['update'] case final List<Object?> list) {
      for (final v in list) {
        if (v is! Map) continue;
        final id = keys[v['id']];
        final text = note(v['text']);
        if (id == null || text == null || update.containsKey(id)) continue;
        update[id] = text;
        if (update.length == maxEach) break;
      }
    }

    final remove = <String>[];
    if (json['remove'] case final List<Object?> list) {
      for (final v in list) {
        final id = keys[v];
        if (id == null || update.containsKey(id) || remove.contains(id)) {
          continue;
        }
        remove.add(id);
        if (remove.length == maxEach) break;
      }
    }
    return MemoryEdits(add: add, update: update, remove: remove);
  }
}

/// Runs [MemoryCurator] after replies, in the engine's idle time, and applies
/// what it decides to [MemoryStore]. With the embedding model on the phone,
/// the model is shown the memories closest in meaning to the user's message
/// and new memories that mean the same as an existing one are dropped;
/// without it, the newest memories are shown and only exact repeats are
/// dropped.
class MemoryKeeper {
  MemoryKeeper({
    required NativeBridge native,
    required MemoryStore memories,
    required ModelManager models,
    required SettingsStore settings,
  }) : _native = native,
       _memories = memories,
       _models = models,
       _settings = settings;

  final NativeBridge _native;
  final MemoryStore _memories;
  final ModelManager _models;
  final SettingsStore _settings;

  /// Memories shown to the model with each exchange.
  static const int shown = 8;

  /// Cosine similarity at which a new memory repeats an existing one.
  static const double sameMeaning = 0.9;

  /// Document vectors of memory texts, filled as memories are compared.
  final Map<String, Float32List> _vectors = {};

  /// Lets the model update memory from one exchange. Returns whether
  /// anything changed; null when [run] was preempted or memory is off.
  Future<bool?> learn(
    BackgroundRun run, {
    required String asked,
    required String reply,
  }) async {
    if (!_settings.memoryEnabled || asked.trim().isEmpty) return null;
    final path = _models.pathOf(embeddingModel);
    final related = path == null
        ? _memories.items.take(shown).toList()
        : await _closest(run, path, asked);
    if (related == null) return null;
    final keys = {for (final (i, m) in related.indexed) 'm${i + 1}': m.id};
    final raw = await run.generate(
      MemoryCurator.prompt(
        userMessage: asked,
        reply: reply,
        related: [for (final (i, m) in related.indexed) ('m${i + 1}', m.text)],
      ),
      maxTokens: MemoryCurator.maxTokens,
    );
    // Memory may have been turned off while the model was answering.
    if (raw == null || !_settings.memoryEnabled) return null;
    final edits = MemoryCurator.parse(raw, keys: keys);
    if (edits.isEmpty) return false;
    // Repeats are judged against memory as the model saw it, before its
    // own updates change it.
    final fresh = [
      for (final text in edits.add)
        if (!_memories.knows(text)) text,
    ];
    final adds = path == null ? fresh : await _novel(run, path, fresh);
    if (adds == null) return null;
    var changed = false;
    for (final MapEntry(key: id, value: text) in edits.update.entries) {
      changed |= await _memories.edit(id, text);
    }
    for (final id in edits.remove) {
      changed |= await _memories.remove(id) != null;
    }
    for (final text in adds) {
      changed |= await _memories.add(text);
    }
    return changed;
  }

  /// The [shown] memories closest in meaning to [message].
  Future<List<Memory>?> _closest(
    BackgroundRun run,
    String path,
    String message,
  ) async {
    if (_memories.items.length <= shown) return _memories.items;
    final query = await run.step(
      () => _native.embed(path, [message], query: true),
    );
    final embedded = await _embedded(run, path);
    if (query == null || embedded == null) return null;
    final ranked = [for (final (m, v) in embedded) (m, _dot(query.single, v))]
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (m, _) in ranked.take(shown)) m];
  }

  /// [candidates] without those that mean the same as an existing memory
  /// or an earlier candidate.
  Future<List<String>?> _novel(
    BackgroundRun run,
    String path,
    List<String> candidates,
  ) async {
    if (candidates.isEmpty) return candidates;
    final embedded = await _embedded(run, path);
    if (embedded == null) return null;
    final vectors = await run.step(
      () => _native.embed(path, candidates, query: false),
    );
    if (vectors == null) return null;
    final kept = [for (final (_, v) in embedded) v];
    final out = <String>[];
    for (final (i, text) in candidates.indexed) {
      final v = vectors[i];
      if (kept.any((k) => _dot(k, v) >= sameMeaning)) continue;
      kept.add(v);
      out.add(text);
      _vectors[text] = v;
    }
    return out;
  }

  /// The memories as they are now, each with its vector, embedding those
  /// not embedded yet; null when preempted.
  Future<List<(Memory, Float32List)>?> _embedded(
    BackgroundRun run,
    String path,
  ) async {
    final items = _memories.items;
    final missing = [
      for (final m in items)
        if (!_vectors.containsKey(m.text)) m.text,
    ];
    if (missing.isNotEmpty) {
      final vectors = await run.step(
        () => _native.embed(path, missing, query: false),
      );
      if (vectors == null) return null;
      for (final (i, text) in missing.indexed) {
        _vectors[text] = vectors[i];
      }
    }
    return [for (final m in items) (m, _vectors[m.text]!)];
  }

  static double _dot(Float32List a, Float32List b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }
}
