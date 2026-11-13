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
  Generation._(this.text, this._native, this._id);

  final Stream<String> text;
  late final Future<RunMetrics> done;
  final NativeBridge _native;
  final int _id;
  bool _cancelRequested = false;

  /// Whether the reply stopped before it was complete: [cancel], or Android
  /// reclaiming the model's memory. Set when [done] completes.
  bool cancelled = false;

  /// Stops this reply whether it is still queued, in prefill or decoding.
  Future<void> cancel() {
    _cancelRequested = true;
    return _native.cancel(_id);
  }
}

class LoadResult {
  const LoadResult(
    this.loadMs,
    this.peakRssMb,
    this.contextSize, {
    this.cacheWrittenMb = 0,
  });

  final double loadMs;
  final double peakRssMb;
  final int contextSize;

  /// What the load added to LiteRT-LM's compiled-program and weight cache:
  /// a first load on a backend builds it, later loads reuse it and write
  /// nothing.
  final double cacheWrittenMb;
}

/// The most recent model load, for diagnostics.
typedef LastLoad = ({ModelSpec spec, BackendOption backend, LoadResult result});

/// Keeps one model resident and serializes all work on it. Loading is lazy:
/// the first [ensureLoaded] (usually a background warm-up) pays the cost and
/// later calls with the same model and backend return at once.
class EngineService extends ChangeNotifier {
  EngineService(this._native) {
    _native.eventsOf('engine').listen((e) {
      if (e['kind'] == 'released') {
        releases++;
        _loadedKey = null;
        _status = EngineStatus.idle;
        notifyListeners();
      }
    });
  }

  final NativeBridge _native;
  Future<void> _queue = Future.value();
  int _nextRequest = 0;
  int? _backgroundRequest;

  /// Times Android made the engine release its model; work that spans a
  /// release (calibration) did not run to completion.
  int releases = 0;

  /// Bumped whenever foreground work arrives; background generations
  /// queued under an older epoch are skipped and a running one is cancelled.
  int _epoch = 0;

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

  LastLoad? lastLoad;

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
        final result = LoadResult(
          (r['loadMs']! as num).toDouble(),
          (r['peakRssMb']! as num).toDouble(),
          _contextSize!,
          cacheWrittenMb: (r['cacheWrittenMb']! as num).toDouble(),
        );
        lastLoad = (spec: spec, backend: backend, result: result);
        notifyListeners();
        return result;
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
    final generation = Generation._(controller.stream, _native, id);
    generation.done = _exclusive(() async {
      try {
        // Native code only learns of the request when it is sent; a cancel
        // while it waited in this queue is honoured here.
        if (generation._cancelRequested) {
          generation.cancelled = true;
          return const RunMetrics();
        }
        final m = await _native.generate(
          requestId: id,
          turns: turns,
          maxTokens: maxTokens,
          temperature: temperature,
          ignoreEos: ignoreEos,
        );
        generation.cancelled = m['cancelled']! as bool;
        return lastRun.value = RunMetrics.fromMap(m);
      } finally {
        // Token events are posted before the method result on the same
        // main-thread queue, so all of them have arrived by now.
        await sub.cancel();
        await controller.close();
      }
    });
    return generation;
  }

  /// Exact per-turn token counts from the loaded model's tokenizer (see
  /// [NativeBridge.countTokens]); queued like any other engine call.
  Future<({List<int>? counts, int? overhead})> countTokens(
    List<EngineTurn> turns,
  ) => _exclusive(() => _native.countTokens(turns));

  /// Gives way to foreground work: queued background generations are
  /// dropped and a running one is cancelled, so the user never waits on
  /// one.
  void preemptBackground() {
    _epoch++;
    if (_backgroundRequest case final id?) unawaited(_native.cancel(id));
  }

  /// Starts a run of background work (titles, memory suggestions,
  /// embedding) that ends for good at the first foreground load or
  /// generation after this call.
  BackgroundRun backgroundRun() => BackgroundRun._(this, _epoch);

  Future<T?> _background<T extends Object>(
    int epoch,
    Future<T?> Function() task,
  ) => _exclusive(() async => epoch == _epoch ? await task() : null);

  /// Frees the model's memory (app backgrounded for long).
  Future<void> release() => _exclusive(() async {
    if (_loadedKey == null) return;
    await _native.unload();
    _loadedKey = null;
    _status = EngineStatus.idle;
    notifyListeners();
  });
}

/// Background steps that each wait for the engine to be free and are all
/// skipped once foreground work has arrived since the run began; a running
/// generation step is cancelled, so the user never waits on one. A step
/// that fails throws, for the caller to report.
class BackgroundRun {
  BackgroundRun._(this._engine, this._epoch);

  final EngineService _engine;
  final int _epoch;

  bool get preempted => _epoch != _engine._epoch;

  /// Runs [task] when the engine is free; null if preempted first. A running
  /// task is not interrupted, so keep tasks short.
  Future<T?> step<T extends Object>(Future<T> Function() task) =>
      _engine._background(_epoch, task);

  /// A short generation on the already loaded model; null if preempted
  /// before or during it, or if no model is loaded (it never loads one).
  Future<String?> generate(
    List<EngineTurn> turns, {
    required int maxTokens,
    double temperature = 0.1,
  }) {
    final e = _engine;
    final id = e._nextRequest++;
    final out = StringBuffer();
    final sub = e._native
        .eventsOf('token')
        .where((ev) => ev['requestId'] == id)
        .listen((ev) => out.write(ev['text']! as String));
    return e
        ._background(_epoch, () async {
          if (e._loadedKey == null) return null;
          e._backgroundRequest = id;
          try {
            await e._native.generate(
              requestId: id,
              turns: turns,
              maxTokens: maxTokens,
              temperature: temperature,
              ignoreEos: false,
            );
            return preempted ? null : out.toString();
          } finally {
            e._backgroundRequest = null;
          }
        })
        .whenComplete(sub.cancel);
  }
}
