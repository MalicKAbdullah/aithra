import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/catalog.dart';
import '../platform/native.dart';
import 'run_metrics.dart';

enum EngineStatus { idle, loading, ready, failed }

/// A streaming reply. [text] emits chunks as the engine produces them;
/// [done] completes with the run's metrics once the engine stops.
class Generation {
  Generation(this.text, this.done, this._cancel);

  final Stream<String> text;
  final Future<RunMetrics> done;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

class LoadResult {
  const LoadResult(this.loadMs, this.peakRssMb, this.contextSize);

  final double loadMs;
  final double peakRssMb;
  final int contextSize;
}

/// Keeps one model resident and serializes all work on it. Loading is lazy:
/// the first [ensureLoaded] (usually a background warm-up) pays the cost and
/// later calls with the same model and backend return at once.
class EngineService extends ChangeNotifier {
  EngineService(this._native) {
    _native.eventsOf('engine').listen((e) {
      if (e['kind'] == 'released') {
        _loadedKey = null;
        _status = EngineStatus.idle;
        notifyListeners();
      }
    });
  }

  final NativeBridge _native;
  Future<void> _queue = Future.value();
  int _nextRequest = 0;

  String? _loadedKey;
  EngineStatus _status = EngineStatus.idle;
  String? _error;
  int? _contextSize;

  EngineStatus get status => _status;
  String? get error => _error;

  /// KV-cache size of the loaded model, once loaded.
  int? get contextSize => _contextSize;

  /// Metrics of the latest generation, for the on-screen performance HUD.
  final ValueNotifier<RunMetrics?> lastRun = ValueNotifier(null);

  bool isLoaded(ModelSpec spec, BackendOption backend) =>
      _loadedKey == _key(spec, backend);

  static String _key(ModelSpec spec, BackendOption b) => '${spec.id}|${b.id}';

  /// Runs [task] after everything queued before it.
  Future<T> _exclusive<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<LoadResult?> ensureLoaded(
    ModelSpec spec,
    String path,
    BackendOption backend,
  ) => _exclusive(() async {
    final key = _key(spec, backend);
    if (_loadedKey == key) return null;
    _status = EngineStatus.loading;
    _error = null;
    notifyListeners();
    try {
      final r = await _native.load(
        runtime: spec.runtime.name,
        path: path,
        backend: backend.nativeId,
        threads: backend.threads,
        vision: spec.vision,
        maxTokens: spec.contextTokens,
      );
      _loadedKey = key;
      _contextSize = r['contextSize']! as int;
      _status = EngineStatus.ready;
      notifyListeners();
      return LoadResult(
        (r['loadMs']! as num).toDouble(),
        (r['peakRssMb']! as num).toDouble(),
        _contextSize!,
      );
    } catch (e) {
      _loadedKey = null;
      _status = EngineStatus.failed;
      _error = e is PlatformException ? e.message : '$e';
      notifyListeners();
      rethrow;
    }
  });

  /// Streams a reply from the loaded model. Call [ensureLoaded] first.
  Generation generate(
    List<EngineTurn> turns, {
    required int maxTokens,
    double temperature = 0.7,
    bool ignoreEos = false,
  }) {
    final id = _nextRequest++;
    final controller = StreamController<String>();
    final sub = _native
        .eventsOf('token')
        .where((e) => e['requestId'] == id)
        .listen((e) => controller.add(e['text']! as String));
    final done = _exclusive(() async {
      try {
        final m = await _native.generate(
          requestId: id,
          turns: turns,
          maxTokens: maxTokens,
          temperature: temperature,
          ignoreEos: ignoreEos,
        );
        return lastRun.value = RunMetrics.fromMap(m);
      } finally {
        // Token events are posted before the method result on the same
        // main-thread queue, so all of them have arrived by now.
        await sub.cancel();
        await controller.close();
      }
    });
    return Generation(controller.stream, done, _native.cancel);
  }

  /// Frees the model's memory (app backgrounded for long).
  Future<void> release() => _exclusive(() async {
    if (_loadedKey == null) return;
    await _native.unload();
    _loadedKey = null;
    _status = EngineStatus.idle;
    notifyListeners();
  });
}
