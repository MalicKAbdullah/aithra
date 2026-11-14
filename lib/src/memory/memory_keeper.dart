import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/settings_store.dart';
import '../engine/engine_service.dart';
import '../models/catalog.dart';
import '../models/model_manager.dart';
import '../platform/native.dart';
import 'memory_curator.dart';
import 'memory_store.dart';
import 'profile.dart';

/// What [MemoryKeeper.rememberExplicit] did.
sealed class RememberResult {
  const RememberResult();
}

/// Filed into the profile; [update] can be undone.
final class Remembered extends RememberResult {
  const Remembered(this.update);
  final MemoryUpdate update;
}

/// The profile already says it.
final class AlreadyRemembered extends RememberResult {
  const AlreadyRemembered();
}

/// Kept, and filed when the engine is next free (the Memory screen lists
/// it until then).
final class RememberLater extends RememberResult {
  const RememberLater();
}

enum _Filed { updated, unchanged, later, invalid }

/// Keeps the user's profile ([MemoryStore]) with the loaded model, only in
/// the engine's idle time: every step is a [BackgroundRun] step, so the
/// user's next message preempts it, and the model's answers pass the
/// validators in memory_curator.dart before anything changes.
///
/// After each reply the user's message goes through the gate; what the
/// user stated or asked to have remembered is filed by rewriting one
/// section, and what they only hinted at becomes a suggestion until they
/// accept it or hint at it again. Things the user asked to remember from a
/// message, and the one-time tidy-up of the old memory list, are worked
/// through whenever the engine has a model and nothing else to do.
class MemoryKeeper {
  MemoryKeeper({
    required NativeBridge native,
    required EngineService engine,
    required MemoryStore memories,
    required ModelManager models,
    required SettingsStore settings,
  }) : _native = native,
       _engine = engine,
       _memories = memories,
       _models = models,
       _settings = settings {
    engine.addListener(_onEngine);
  }

  final NativeBridge _native;
  final EngineService _engine;
  final MemoryStore _memories;
  final ModelManager _models;
  final SettingsStore _settings;

  /// Cosine similarity at which two lines say the same thing.
  static const double sameMeaning = 0.9;

  /// Lines from the work, interests and projects sections given to a chat;
  /// with more than this, the ones closest in meaning to the message go.
  static const int picked = 10;

  /// Why the last background pass failed, shown on the Memory screen;
  /// null once one succeeds.
  final ValueNotifier<String?> failure = ValueNotifier(null);

  /// Document vectors of profile lines and suggestions, by text.
  final Map<String, Float32List> _vectors = {};

  Future<void> _work = Future.value();
  EngineStatus _lastStatus = EngineStatus.idle;

  bool get _on => _settings.memoryEnabled && _memories.loaded;

  /// Runs model work one piece at a time, so each rewrite starts from the
  /// profile the last one left.
  Future<T> _serially<T>(Future<T> Function() task) {
    final result = _work.then((_) => task());
    _work = result.then((_) {}, onError: (_) {});
    return result;
  }

  void _onEngine() {
    final now = _engine.status;
    if (now == EngineStatus.ready && _lastStatus != EngineStatus.ready) {
      unawaited(catchUpInBackground());
    }
    _lastStatus = now;
  }

  /// [catchUp] in a run of its own, its failure kept in [failure].
  Future<void> catchUpInBackground() async {
    try {
      await catchUp(_engine.backgroundRun());
      failure.value = null;
    } on PlatformException catch (e) {
      failure.value = e.message ?? e.code;
    }
  }

  // -- After a reply -------------------------------------------------------

  /// Lets the model judge the user's message [asked] and file what it
  /// finds. Returns the change to the profile, or null when there is none
  /// (nothing worth keeping, only a suggestion, or preempted).
  Future<MemoryUpdate?> learn(BackgroundRun run, {required String asked}) =>
      _serially(() async {
        if (!_on || asked.trim().isEmpty) return null;
        final raw = await run.generate(
          MemoryGate.prompt(asked),
          maxTokens: MemoryGate.maxTokens,
        );
        if (raw == null || !_on) return null;
        final verdict = MemoryGate.parse(raw, asked);
        if (verdict == null) return null;
        switch (verdict.kind) {
          case GateKind.stated:
            return (await _file(run, verdict.quote, MemoryOrigin.stated)).$2;
          case GateKind.asked:
            return (await _file(run, verdict.quote, MemoryOrigin.asked)).$2;
          case GateKind.implied:
            return _suggest(run, verdict.quote);
        }
      });

  /// Files waiting memories, sorts old ones into the profile and embeds
  /// new lines for [forPrompt], until done or preempted.
  Future<void> catchUp(BackgroundRun run) => _serially(() async {
    if (!_on) return;
    for (final p in _memories.pending) {
      if (p.stuck || _claimed.contains(p.id)) continue;
      final (outcome, _) = await _filePending(run, p);
      if (outcome == _Filed.later) return;
    }
    if (!await _tidy(run)) return;
    final path = _models.pathOf(embeddingModel);
    if (path != null) {
      await _embedMissing(run, path, [
        for (final i in _memories.items) i.text,
        for (final s in _memories.suggested) s.text,
      ]);
    }
  });

  // -- "Remember this" -----------------------------------------------------

  /// Files [text], a message the user explicitly asked Aithra to remember,
  /// into the profile without asking the gate. It is saved first, so it is
  /// never lost: when the engine is busy or the user's next message
  /// preempts the model, it stays waiting (see [MemoryStore.pending]) and
  /// is filed in a later idle moment.
  ///
  /// Callers offer it only while memory is on and the chat does not skip
  /// memory (see ChatSession.skipMemory).
  Future<RememberResult> rememberExplicit(String text) async {
    if (!_settings.memoryEnabled) {
      throw StateError('Remember this is offered only while memory is on');
    }
    final p = PendingMemory(id: MemoryStore.newId(), text: text.trim());
    _claimed.add(p.id);
    await _memories.queue(p);
    final run = _engine.backgroundRun();
    return _serially(() async {
      try {
        return switch (await _filePending(run, p)) {
          (_Filed.updated, final update?) => Remembered(update),
          (_Filed.unchanged, _) => const AlreadyRemembered(),
          _ => const RememberLater(),
        };
      } finally {
        _claimed.remove(p.id);
      }
    });
  }

  /// Waiting memories a [rememberExplicit] call is filing itself, so a
  /// [catchUp] queued before it leaves them alone.
  final Set<String> _claimed = {};

  Future<(_Filed, MemoryUpdate?)> _filePending(
    BackgroundRun run,
    PendingMemory p,
  ) async {
    final filed = await _file(run, p.text, MemoryOrigin.asked);
    switch (filed.$1) {
      case _Filed.updated || _Filed.unchanged:
        await _memories.settle(p.id);
      case _Filed.invalid:
        await _memories.failed(p.id);
      case _Filed.later:
        break;
    }
    return filed;
  }

  // -- The model's steps ---------------------------------------------------

  ProfileText _profileText() => {
    for (final s in ProfileSection.values)
      s: [for (final i in _memories.section(s)) i.text],
  };

  /// Rewrites the section [words] belong to. A profile changed by the user
  /// while the model was writing makes the answer stale: it is dropped and
  /// counts as [_Filed.later].
  Future<(_Filed, MemoryUpdate?)> _file(
    BackgroundRun run,
    String words,
    MemoryOrigin origin,
  ) async {
    final revision = _memories.revision;
    final profile = _profileText();
    final raw = await run.generate(
      ProfileRewriter.prompt(profile: profile, words: words, origin: origin),
      maxTokens: ProfileRewriter.maxTokens,
    );
    if (raw == null || !_on || _memories.revision != revision) {
      return (_Filed.later, null);
    }
    final rewrite = ProfileRewriter.parse(raw, profile);
    if (rewrite == null) return (_Filed.invalid, null);
    final update = await _memories.rewrite(
      rewrite.section,
      rewrite.items,
      origin: origin,
    );
    return (update == null ? _Filed.unchanged : _Filed.updated, update);
  }

  /// Turns a hint into a suggestion, or files it when the same hint is
  /// already waiting as a suggestion: said twice, it is no passing remark.
  Future<MemoryUpdate?> _suggest(BackgroundRun run, String words) async {
    final raw = await run.generate(
      SuggestionWriter.prompt(words),
      maxTokens: SuggestionWriter.maxTokens,
    );
    if (raw == null || !_on) return null;
    final note = SuggestionWriter.parse(raw);
    if (note == null) return null;
    final (section, text) = note;
    final path = _models.pathOf(embeddingModel);
    final vectors = path == null
        ? null
        : await _embedMissing(run, path, [
            text,
            for (final i in _memories.items) i.text,
            for (final s in _memories.suggested) s.text,
          ]);
    if (path != null && vectors == null) return null;
    bool same(String other) => vectors == null
        ? _norm(other) == _norm(text)
        : _dot(vectors[text]!, vectors[other]!) >= sameMeaning;
    if (_memories.items.any((i) => same(i.text))) return null;
    final again = _memories.suggested.where((s) => same(s.text)).firstOrNull;
    if (again == null) {
      await _memories.suggest(section, text);
      return null;
    }
    final (outcome, update) = await _file(run, text, MemoryOrigin.implied);
    if (outcome == _Filed.updated || outcome == _Filed.unchanged) {
      await _memories.promote(again.id);
    }
    return update;
  }

  static String _norm(String s) =>
      s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  /// Sorts the old memory list into the profile a batch at a time. Returns
  /// false when preempted.
  Future<bool> _tidy(BackgroundRun run) async {
    while (_on && _memories.tidying) {
      final batch = _memories.untidied.take(MemoryTidier.batch).toList();
      if (_memories.tidyFailures >= MemoryPolicy.attempts) {
        await _memories.setAsideUnsorted(batch);
        continue;
      }
      final revision = _memories.revision;
      final notes = {for (final (i, n) in batch.indexed) 'n${i + 1}': n.id};
      final existing = _memories.tidyLines;
      final lines = {
        for (final (i, (s, item)) in existing.indexed)
          'p${i + 1}': (s, item.id),
      };
      final raw = await run.generate(
        MemoryTidier.prompt(
          notes: [for (final (i, n) in batch.indexed) ('n${i + 1}', n.text)],
          lines: [
            for (final (i, (s, item)) in existing.indexed)
              ('p${i + 1}', s, item.text),
          ],
        ),
        maxTokens: MemoryTidier.maxTokens,
      );
      if (raw == null) return false;
      if (_memories.revision != revision) continue;
      final parsed = MemoryTidier.parse(
        raw,
        notes: notes,
        lines: lines,
        sizes: {
          for (final s in ProfileSection.values) s: _memories.section(s).length,
        },
      );
      if (parsed == null) {
        await _memories.tidyFailed();
      } else {
        await _memories.applyTidy(batch, parsed);
      }
    }
    return true;
  }

  /// Vectors for [texts], embedding those not cached yet; null when
  /// preempted.
  Future<Map<String, Float32List>?> _embedMissing(
    BackgroundRun run,
    String path,
    List<String> texts,
  ) async {
    final missing = {
      for (final t in texts)
        if (!_vectors.containsKey(t)) t,
    }.toList();
    if (missing.isNotEmpty) {
      final vectors = await run.step(
        () => _native.embed(path, missing, query: false),
      );
      if (vectors == null) return null;
      for (final (i, t) in missing.indexed) {
        _vectors[t] = vectors[i];
      }
    }
    return {for (final t in texts) t: _vectors[t]!};
  }

  // -- Into a chat ---------------------------------------------------------

  /// The profile lines for a chat's system prompt, in section order: all
  /// of About and Preferences, then the work, interests and projects lines,
  /// only the [picked] closest in meaning to [message] when there are more
  /// (with [rank], when the embedding model works this turn). Old memories
  /// not tidied yet come last. A prompt over budget sheds from the end
  /// (see SystemContext.shed), so who the user is goes last.
  Future<List<String>> forPrompt(String message, {required bool rank}) async {
    const core = [ProfileSection.about, ProfileSection.preferences];
    final rest = [
      for (final s in ProfileSection.values)
        if (!core.contains(s)) ..._memories.section(s),
    ];
    var chosen = rest;
    final path = _models.pathOf(embeddingModel);
    if (rank && path != null && rest.length > picked) {
      final missing = [
        for (final i in rest)
          if (!_vectors.containsKey(i.text)) i.text,
      ];
      final query = await _native.embed(path, [message], query: true);
      if (missing.isNotEmpty) {
        final vectors = await _native.embed(path, missing, query: false);
        for (final (i, t) in missing.indexed) {
          _vectors[t] = vectors[i];
        }
      }
      final ranked = [...rest]
        ..sort(
          (a, b) => _dot(
            query.single,
            _vectors[b.text]!,
          ).compareTo(_dot(query.single, _vectors[a.text]!)),
        );
      final keep = ranked.take(picked).toSet();
      chosen = [
        for (final i in rest)
          if (keep.contains(i)) i,
      ];
    }
    return [
      for (final s in core)
        for (final i in _memories.section(s)) i.text,
      for (final i in chosen) i.text,
      for (final m in _memories.untidied) m.text,
    ];
  }

  static double _dot(Float32List a, Float32List b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }
}
