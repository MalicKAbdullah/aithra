import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../assistant.dart';
import '../engine/run_metrics.dart';
import '../models/catalog.dart';
import '../platform/native.dart';
import 'documents.dart';

/// What a document's preparation is doing.
enum PrepStage {
  /// The vision model is reading its scanned pages.
  reading,

  /// Its passages are being embedded for search.
  indexing,
}

/// Where a document's preparation stands: [done] of [total] pages read or
/// passages embedded.
typedef PrepProgress = ({PrepStage stage, int done, int total});

/// The chip line for [p]: "Reading · 60%".
String prepLabel(PrepProgress p) {
  final percent = p.total == 0 ? 0 : (p.done * 100 ~/ p.total);
  return switch (p.stage) {
    PrepStage.reading => 'Reading · $percent%',
    PrepStage.indexing => 'Indexing · $percent%',
  };
}

/// Gets documents ready to be asked about as soon as they are attached,
/// rather than when the question comes: the vision model reads scanned
/// pages, then EmbeddingGemma embeds every passage, so a question only
/// waits for whatever is still left. Both run as housekeeping (see
/// BackgroundRun): one document at a time, giving way to every reply,
/// pausing while Aithra is off screen and carrying on from what is stored.
class DocPreparer extends ChangeNotifier {
  DocPreparer({required NativeBridge native, required Assistant assistant})
    : _native = native,
      _assistant = assistant;

  final NativeBridge _native;
  final Assistant _assistant;

  /// Passages embedded per step; each step holds the engine's queue, so a
  /// reply waits at most for one.
  static const int batch = 8;

  /// Documents being prepared or waiting their turn, by id.
  final Map<String, PrepProgress> progress = {};

  final Set<String> _dropped = {};
  final Set<String> _seen = {};
  Future<void> _work = Future.value();

  /// Why preparing a document failed, by id; its questions then do the
  /// remaining work themselves.
  final Map<String, String> failures = {};

  /// Prepares [doc] in the background; a document already prepared, or on
  /// its way, is left alone.
  void prepare(DocInfo doc) {
    if (!_seen.add(doc.id)) return;
    progress[doc.id] = (
      stage: doc.unreadPages > 0 ? PrepStage.reading : PrepStage.indexing,
      done: 0,
      total: 0,
    );
    notifyListeners();
    // Each document's work starts after the previous one's, whatever its
    // outcome; an unexpected error still reaches the crash report.
    _work = _work
        .then((_) => _run(doc))
        .then(
          (_) {},
          onError: (Object e, StackTrace s) =>
              Zone.current.handleUncaughtError(e, s),
        );
  }

  /// Stops preparing [id], a document the user removed.
  void drop(String id) {
    if (progress.remove(id) == null) return;
    _dropped.add(id);
    notifyListeners();
  }

  /// Prepares the documents in chats that a closed app left unprepared.
  Future<void> resumePending() async {
    final rows = await _native.unpreparedDocuments(
      withPassages: _assistant.models.pathOf(embeddingModel) != null,
    );
    for (final row in rows) {
      prepare(DocInfo.fromMap(row));
    }
  }

  Future<void> _run(DocInfo doc) async {
    try {
      if (doc.unreadPages > 0) await _readPages(doc);
      if (_dropped.contains(doc.id)) return;
      await _index(doc);
    } on PlatformException catch (e) {
      failures[doc.id] = e.message ?? e.code;
    } on StateError catch (e) {
      failures[doc.id] = e.message;
    } finally {
      _dropped.remove(doc.id);
      progress.remove(doc.id);
      notifyListeners();
    }
  }

  void _show(DocInfo doc, PrepStage stage, int done, int total) {
    if (!progress.containsKey(doc.id)) return;
    progress[doc.id] = (stage: stage, done: done, total: total);
    notifyListeners();
  }

  /// Reads the scanned pages one at a time with the vision model. A page a
  /// reply read meanwhile (it reads what it needs itself) is skipped.
  Future<void> _readPages(DocInfo doc) async {
    final engine = _assistant.engine;
    final total = doc.unreadPages;
    final clock = Stopwatch()..start();
    var read = 0;
    while (!_dropped.contains(doc.id)) {
      await engine.whenHousekeepingAllowed();
      final spec = _assistant.activeModel;
      if (spec == null || !spec.vision) return;
      final pages = await _native.unreadPages(doc.id);
      if (pages.isEmpty) break;
      _show(doc, PrepStage.reading, total - pages.length, total);
      final page = pages.first;
      final image = await _native.dbImage(
        page['image']! as String,
        thumb: false,
      );
      // The image goes once its page is read (by a reply) or its document
      // is deleted; the list read again says which.
      if (image == null) continue;
      final backend = _assistant.backendFor(spec);
      if (backend == null) return;
      // Loading the model is housekeeping too: only with the app on screen
      // and no reply running, which holds after the wait above.
      if (!engine.isLoaded(spec, backend)) await _assistant.prepare();
      final pageClock = Stopwatch()..start();
      final text = await engine.backgroundRun().generate(
        [
          EngineTurn('user', readPagePrompt, [image]),
        ],
        maxTokens: readPageTokens,
        temperature: 0,
      );
      // Preempted by a reply: the loop waits for it, then reads again.
      if (text == null) continue;
      await _native.setPageText(doc.id, page['page']! as int, text);
      read++;
      logStage(
        'aithra.docs',
        'scannedInBackground page=${page['page']} '
            'ms=${pageClock.elapsedMilliseconds}',
      );
    }
    logStage(
      'aithra.docs',
      'scannedInBackground pages=$read totalMs=${clock.elapsedMilliseconds}',
    );
  }

  /// Embeds the passages a batch at a time, while the embedding model is on
  /// the phone.
  Future<void> _index(DocInfo doc) async {
    final engine = _assistant.engine;
    final clock = Stopwatch()..start();
    var embedded = 0;
    while (!_dropped.contains(doc.id)) {
      final path = _assistant.models.pathOf(embeddingModel);
      if (path == null) return;
      final step = await engine.backgroundRun().step(
        () => _native.indexDocument(path, doc.id, batch),
      );
      // Preempted by a reply before it ran: the next step waits for it.
      if (step == null) continue;
      if (step.embedded == 0) break;
      embedded += step.embedded;
      _show(doc, PrepStage.indexing, step.indexed, step.total);
    }
    if (embedded > 0) {
      logStage(
        'aithra.docs',
        'indexedInBackground passages=$embedded '
            'ms=${clock.elapsedMilliseconds}',
      );
    }
  }
}
