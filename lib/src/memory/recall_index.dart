import 'dart:async';

import 'package:flutter/services.dart';

import '../engine/engine_service.dart';
import '../model_output.dart';
import '../models/catalog.dart';
import '../models/download_state.dart';
import '../models/model_manager.dart';
import '../platform/native.dart';

/// Cross-chat recall by meaning. Messages are embedded by [embeddingModel]
/// in small batches whenever the engine is free, and a new message's
/// nearest past messages from other chats are added to the prompt. Without
/// the embedding model, recall is off.
class RecallIndex {
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

  String? get _path => _models.pathOf(embeddingModel);
  bool get available => _path != null;

  void _onModelsChanged() {
    final now = _models.availability(embeddingModel) is Ready;
    if (now && !_wasAvailable) indexInBackground();
    _wasAvailable = now;
  }

  /// Past messages from chats other than [excludeConv] related to [query].
  Future<List<String>> recall(String query, String excludeConv) async {
    final path = _path;
    if (path == null || query.trim().isEmpty) return const [];
    try {
      final rows = await _native.dbRecall(path, query, excludeConv, maxResults);
      return [
        for (final r in rows)
          clipChars(oneLine(r['content']! as String) ?? '', maxChars),
      ];
    } on PlatformException {
      // Recall only adds context; a reply must not fail because the
      // optional embedding model could not run.
      return const [];
    }
  }

  /// Embeds unindexed messages, one batch per free moment of the engine,
  /// until all are done or the user needs the engine.
  void indexInBackground() {
    _indexing ??= _indexAll().whenComplete(() => _indexing = null);
  }

  Future<void> _indexAll() async {
    final run = _engine.backgroundRun();
    while (true) {
      final path = _path;
      if (path == null) return;
      final n = await run.step(() => _native.dbIndexVectors(path, batch));
      if (n == null || n == 0) return;
    }
  }

  void dispose() => _models.removeListener(_onModelsChanged);
}
