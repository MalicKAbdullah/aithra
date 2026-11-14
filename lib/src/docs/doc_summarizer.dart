import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../assistant.dart';
import '../chat/context_builder.dart';
import '../models/catalog.dart';
import '../platform/native.dart';
import 'documents.dart';

/// Where a document summary stands: parts written of the parts planned.
typedef SummaryProgress = ({int done, int total});

/// A summary of a whole document, which rarely fits in one prompt: each
/// group of pages is summarised on its own (map), then the part summaries
/// are combined (reduce). It runs as background work on the engine, giving
/// way to every chat reply and picking up where it left off; each finished
/// part is stored, so closing the app loses at most the part in progress.
/// The summary is posted to the document's chat as a reply.
class DocSummarizer extends ChangeNotifier {
  DocSummarizer({
    required NativeBridge native,
    required Assistant assistant,
    required void Function(String convId) onPosted,
  }) : _native = native,
       _assistant = assistant,
       _onPosted = onPosted;

  final NativeBridge _native;
  final Assistant _assistant;
  final void Function(String convId) _onPosted;

  /// Tokens one part summary may take.
  static const int partTokens = 320;

  /// Tokens the final summary may take.
  static const int summaryTokens = 700;

  /// Summaries in progress, by document id.
  final Map<String, SummaryProgress> running = {};

  /// Why a summary stopped, by document id.
  final Map<String, String> failures = {};

  /// Resumes summaries the app was closed during.
  Future<void> resumePending() async {
    for (final row in await _native.pendingSummaries()) {
      unawaited(summarize(DocInfo.fromMap(row)));
    }
  }

  /// Summarises [sent], a document sent in a chat.
  Future<void> summarize(DocInfo sent) async {
    if (running.containsKey(sent.id)) return;
    final convId = sent.convId!;
    failures.remove(sent.id);
    running[sent.id] = (done: 0, total: 0);
    notifyListeners();
    final tag = 'summary-${sent.id}';
    try {
      // The stored row, with the parts of a summary already under way.
      final doc = DocInfo.fromMap((await _native.document(sent.id))!);
      final summary = doc.summary ?? await _summarize(doc, tag);
      await _native.dbAddMessage(
        convId: convId,
        role: 'model',
        content: '**Summary of ${doc.name}**\n\n$summary',
        images: const [],
        stats: null,
        now: DateTime.now().millisecondsSinceEpoch,
      );
      await _native.notifyProgress(
        tag: tag,
        title: 'Summary ready',
        text: doc.name,
      );
      _onPosted(convId);
    } on PlatformException catch (e) {
      failures[sent.id] = e.message ?? e.code;
      await _native.cancelNotification(tag);
    } on StateError catch (e) {
      failures[sent.id] = e.message;
      await _native.cancelNotification(tag);
    } finally {
      running.remove(sent.id);
      notifyListeners();
    }
  }

  Future<String> _summarize(DocInfo doc, String tag) async {
    final spec = await _ready();
    final contextSize = _assistant.engine.contextSize!;
    final pages = [
      for (final p in await _native.documentPages(doc.id))
        (page: doc.paged ? p['page']! as int : 0, text: p['text']! as String),
    ];
    if (pages.isEmpty) {
      throw StateError('${doc.name} has no text Aithra could read.');
    }
    final measure = _costs(spec);
    final saved = doc.summaryParts;
    final _Plan plan;
    if (saved != null) {
      plan = _Plan.fromJson(jsonDecode(saved) as Map<String, Object?>);
    } else {
      final instruction = (await measure([
        mapPrompt(doc.name, 'pages 1–1', ''),
      ])).single;
      plan = _Plan(
        groups: groupPages([
          for (final c in await measure([for (final p in pages) p.text])) c,
        ], budget: contextSize - partTokens - instruction),
        parts: [],
      );
      await _save(doc.id, plan);
    }
    Future<int> cost(String text) async => (await measure([text])).single;
    for (var i = plan.parts.length; i < plan.groups.length; i++) {
      running[doc.id] = (done: i, total: plan.groups.length);
      notifyListeners();
      await _native.notifyProgress(
        tag: tag,
        title: 'Summarising ${doc.name}',
        text: 'Part ${i + 1} of ${plan.groups.length}',
        done: i,
        total: plan.groups.length,
      );
      final (from, to) = plan.groups[i];
      final group = pages.sublist(from, to + 1);
      final range = doc.paged
          ? 'pages ${group.first.page}–${group.last.page}'
          : 'part ${i + 1} of ${plan.groups.length}';
      final text = group.map((p) => p.text.trim()).join('\n\n');
      plan.parts.add(
        await _step(
          mapPrompt(doc.name, range, text),
          partTokens,
          contextSize,
          cost,
        ),
      );
      await _save(doc.id, plan);
    }
    var parts = plan.parts;
    if (plan.groups.length == 1) return _finish(doc, parts.single);
    // Part summaries that together outgrow the context are combined in
    // rounds until one prompt holds them all.
    final room = contextSize - summaryTokens;
    while (parts.length > 1 &&
        await cost(reducePrompt(doc.name, parts)) > room) {
      final costs = await measure(parts);
      final rounds = groupPages(costs, budget: room ~/ 2);
      parts = [
        for (final (from, to) in rounds)
          await _step(
            reducePrompt(doc.name, parts.sublist(from, to + 1)),
            partTokens,
            contextSize,
            cost,
          ),
      ];
    }
    return _finish(
      doc,
      await _step(
        reducePrompt(doc.name, parts),
        summaryTokens,
        contextSize,
        cost,
      ),
    );
  }

  Future<String> _finish(DocInfo doc, String summary) async {
    await _native.setDocumentSummary(doc.id, summary: summary);
    return summary;
  }

  Future<void> _save(String id, _Plan plan) =>
      _native.setDocumentSummary(id, parts: jsonEncode(plan.toJson()));

  /// The model that will run the summary, loaded.
  Future<ModelSpec> _ready() async {
    final prepared = await _assistant.prepare();
    if (prepared == null) {
      throw StateError('No model is ready. Download one in Models.');
    }
    return prepared.$1;
  }

  Future<List<int>> Function(List<String>) _costs(ModelSpec spec) =>
      (texts) async {
        final r = await _assistant.engine.countTokens([
          for (final t in texts) EngineTurn('user', t),
        ]);
        final ratio = _assistant.tokensPerByte(spec);
        return r.counts ?? [for (final t in texts) estimateTokens(t, ratio)];
      };

  /// One generation as background work: it waits for the engine to be
  /// free and starts over whenever a chat reply takes the engine first.
  Future<String> _step(
    String prompt,
    int maxTokens,
    int contextSize,
    Future<int> Function(String) cost,
  ) async {
    final fitted = await fitMessage(
      PromptMessage(
        seq: 0,
        isUser: true,
        text: prompt,
        tokens: await cost(prompt),
      ),
      room: contextSize - maxTokens,
      cost: cost,
    );
    final engine = _assistant.engine;
    while (true) {
      await engine.whenIdle();
      final spec = _assistant.activeModel;
      final backend = spec == null ? null : _assistant.backendFor(spec);
      if (spec == null || backend == null) {
        throw StateError('No model is ready. Download one in Models.');
      }
      // A reload preempts background work, so it only happens when Android
      // took the model back.
      if (!engine.isLoaded(spec, backend)) await _ready();
      final out = await engine.backgroundRun().generate(
        [EngineTurn('user', fitted.text)],
        maxTokens: maxTokens,
        temperature: 0.2,
      );
      if (out != null) return out.trim();
    }
  }
}

/// Consecutive runs of [costs] (first and last index) that each fit
/// [budget]; an item over the budget on its own is a run of one, which the
/// step then shortens to fit.
List<(int, int)> groupPages(List<int> costs, {required int budget}) {
  final groups = <(int, int)>[];
  var start = 0;
  var used = 0;
  for (var i = 0; i < costs.length; i++) {
    if (i > start && used + costs[i] > budget) {
      groups.add((start, i - 1));
      start = i;
      used = 0;
    }
    used += costs[i];
  }
  if (costs.isNotEmpty) groups.add((start, costs.length - 1));
  return groups;
}

String mapPrompt(String name, String range, String text) =>
    'Summarise this part of "$name" ($range) in at most 150 words. Keep '
    'names, numbers, dates and decisions. Write plain sentences with no '
    'preamble.\n\n$text';

String reducePrompt(String name, List<String> parts) {
  final b = StringBuffer(
    'These are summaries of consecutive parts of "$name". Write one summary '
    'of the whole document in at most 250 words: first what it is and what '
    'it is about, then its main points as a short list.\n',
  );
  for (final (i, p) in parts.indexed) {
    b
      ..writeln()
      ..writeln('Part ${i + 1}:')
      ..writeln(p);
  }
  return b.toString().trimRight();
}

/// A summary's groups of pages (indexes into the document's text pages)
/// and the part summaries written so far, stored as it goes.
class _Plan {
  _Plan({required this.groups, required this.parts});

  factory _Plan.fromJson(Map<String, Object?> j) => _Plan(
    groups: [
      for (final g in j['groups']! as List)
        ((g as List)[0] as int, g[1] as int),
    ],
    parts: [for (final p in j['parts']! as List) p as String],
  );

  final List<(int, int)> groups;
  final List<String> parts;

  Map<String, Object?> toJson() => {
    'groups': [
      for (final (a, b) in groups) [a, b],
    ],
    'parts': parts,
  };
}
