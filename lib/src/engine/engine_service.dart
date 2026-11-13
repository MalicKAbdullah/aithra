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

  /// Bumped whenever foreground work arrives; background generations
  /// queued under an older epoch are skipped and a running one is cancelled.
  int _epoch = 0;
  bool _backgroundRunning = false;

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
  ) {
    preemptBackground();
    return _exclusive(() async {
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
  }

  /// Streams a reply from the loaded model. Call [ensureLoaded] first.
  Generation generate(
    List<EngineTurn> turns, {
    required int maxTokens,
    double temperature = 0.7,
    bool ignoreEos = false,
  }) {
    preemptBackground();
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

  /// Gives way to foreground work: queued background generations are
  /// dropped and a running one is cancelled, so the user never waits on
  /// one.
  void preemptBackground() {
    _epoch++;
    if (_backgroundRunning) unawaited(_native.cancel());
  }

  /// A short generation for Aithra's own housekeeping (titles, memory
  /// suggestions) on the already loaded model. It runs only once the
  /// engine is free and returns null if any foreground work arrives first
  /// or meanwhile, or if no model is loaded; it never loads one.
  Future<String?> generateInBackground(
    List<EngineTurn> turns, {
    required int maxTokens,
    double temperature = 0.1,
  }) {
    final epoch = _epoch;
    final id = _nextRequest++;
    final out = StringBuffer();
    final sub = _native
        .eventsOf('token')
        .where((e) => e['requestId'] == id)
        .listen((e) => out.write(e['text']! as String));
    return _exclusive(() async {
      try {
        if (epoch != _epoch || _loadedKey == null) return null;
        _backgroundRunning = true;
        await _native.generate(
          requestId: id,
          turns: turns,
          maxTokens: maxTokens,
          temperature: temperature,
          ignoreEos: false,
        );
        return epoch == _epoch ? out.toString() : null;
      } on PlatformException {
        return null;
      } finally {
        _backgroundRunning = false;
        await sub.cancel();
      }
    });
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
