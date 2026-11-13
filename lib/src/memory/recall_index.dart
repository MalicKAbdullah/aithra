import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../engine/engine_service.dart';
import '../model_output.dart';
import '../models/catalog.dart';
import '../models/download_state.dart';
import '../models/model_manager.dart';
import '../platform/native.dart';

/// What recall gave a new message.
sealed class RecallOutcome {
  const RecallOutcome();
}

/// The embedding model is not on the phone; recall is off.
class RecallOff extends RecallOutcome {
  const RecallOff();
}

class Recalled extends RecallOutcome {
  const Recalled(this.snippets);
  final List<String> snippets;
}

/// Recall is not working; the reply goes ahead without it and says so.
class RecallFailed extends RecallOutcome {
  const RecallFailed(this.message);
  final String message;
}

/// A message found by meaning from the search box.
class SearchHit {
  const SearchHit({
    required this.convId,
    required this.snippet,
    required this.score,
  });

  final String convId;
  final String snippet;
  final double score;
}

/// Cross-chat recall and message search by meaning. Messages are embedded
/// by [embeddingModel] in small batches whenever the engine is free. A
/// failure, while recalling or indexing, is kept in [failure] and shown to
/// the user; recall then stays off until [retry] or the model is
/// downloaded again.
class RecallIndex extends ChangeNotifier {
  RecallIndex({
    required NativeBridge native,
    required EngineService engine,
    required ModelManager models,
  }) : _native = native,
       _engine = engine,
       _models = models {
    models.addListener(_onModelsChanged);
  }

  final NativeBridge _native;
  final EngineService _engine;
  final ModelManager _models;

  /// Messages embedded per background step; small, so the user's next
  /// message waits at most for one step.
  static const int batch = 4;
  static const int maxResults = 3;
  static const int maxChars = 240;

  Future<void>? _indexing;
  bool _wasAvailable = false;

  /// Why recall is not working, or null.
  String? failure;

  /// Messages with a vector, and all messages; null until first read.
  int? indexed;
  int? total;

  String? get _path => _models.pathOf(embeddingModel);
  bool get available => _path != null;

  void _onModelsChanged() {
    final now = _models.availability(embeddingModel) is Ready;
    if (now && !_wasAvailable) {
      // A fresh download is a fresh start.
      failure = null;
      notifyListeners();
      indexInBackground();
    }
    _wasAvailable = now;
  }

  void _fail(PlatformException e) {
    failure = e.message ?? e.code;
    notifyListeners();
  }

  /// Clears a failure and starts indexing again.
  void retry() {
    failure = null;
    notifyListeners();
    indexInBackground();
  }

  /// Past messages from chats other than [excludeConv] related to [query].
  Future<RecallOutcome> recall(String query, String excludeConv) async {
    final path = _path;
    if (path == null) return const RecallOff();
    final failed = failure;
    if (failed != null) return RecallFailed(failed);
    if (query.trim().isEmpty) return const Recalled([]);
    try {
      final rows = await _native.dbRecall(path, query, excludeConv, maxResults);
      return Recalled([
        for (final r in rows)
          clipChars(oneLine(r['content']! as String) ?? '', maxChars),
      ]);
    } on PlatformException catch (e) {
      _fail(e);
      return RecallFailed(failure!);
    }
  }

  /// Messages whose meaning matches [query], best first; empty while recall
  /// is off or failing (the Models screen shows why).
  Future<List<SearchHit>> search(String query) async {
    final path = _path;
    if (path == null || failure != null || query.trim().isEmpty) {
      return const [];
    }
    try {
      final rows = await _native.dbSearchMessages(path, query, 20);
      return [
        for (final r in rows)
          SearchHit(
            convId: r['convId']! as String,
            snippet: clipChars(oneLine(r['content']! as String) ?? '', 160),
            score: (r['score']! as num).toDouble(),
          ),
      ];
    } on PlatformException catch (e) {
      _fail(e);
      return const [];
    }
  }

  /// Embeds unindexed messages, one batch per free moment of the engine,
  /// until all are done or the user needs the engine.
  void indexInBackground() {
    if (failure != null) return;
    _indexing ??= _indexAll().whenComplete(() => _indexing = null);
  }

  Future<void> _indexAll() async {
    final run = _engine.backgroundRun();
    try {
      await _readStatus();
      while (true) {
        final path = _path;
        if (path == null) return;
        final n = await run.step(() => _native.dbIndexVectors(path, batch));
        if (n == null || n == 0) return;
        await _readStatus();
      }
    } on PlatformException catch (e) {
      _fail(e);
    }
  }

  Future<void> _readStatus() async {
    final s = await _native.dbVectorStatus();
    indexed = s.indexed;
    total = s.total;
    notifyListeners();
  }

  @override
  void dispose() {
    _models.removeListener(_onModelsChanged);
    super.dispose();
  }
}
