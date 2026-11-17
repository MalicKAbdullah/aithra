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

  /// Whether the reply stopped before it was complete: [cancel] or Android
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
    // The app and the Ask sheet each run an EngineService on the one native
    // model, so a load or unload by either changes what the other has. This
    // service's own load reports `loaded` before its result arrives.
    _native.eventsOf('engine').listen((e) {
      if (e['kind'] == 'released') releases++;
      if (_status == EngineStatus.loading) return;
      _loadedKey = null;
      _status = EngineStatus.idle;
      notifyListeners();
    });
    var told = false;
    _native.eventsOf('visibility').listen((e) {
      told = true;
      _setVisible(e['visible']! as bool);
    });
    unawaited(
      _native.appVisible().then((v) {
        if (!told) _setVisible(v);
      }),
    );
    _native.eventsOf('reply').listen((e) {
      if (e['kind'] == 'stop') {
        for (final stop in _holds.values.toList()) {
          stop();
        }
      }
    });
  }

  final NativeBridge _native;
  Future<void> _queue = Future.value();
  int _nextRequest = 0;
  int? _backgroundRequest;

  /// Whether an Aithra activity is on screen. A Flutter engine starts for
  /// an activity coming on screen; native code answers for certain at once.
  bool _visible = true;
  bool get visible => _visible;

  /// Times the app left the screen: background work interrupted by one
  /// runs again once the app is back, rather than giving up.
  int _pauses = 0;
  int get pauses => _pauses;

  /// Replies the user is waiting for (see [holdReply]), with their Stop.
  final Map<int, VoidCallback> _holds = {};
  int _nextHold = 0;

  /// Whether a reply the user waits for is in progress.
  bool get replying => _holds.isNotEmpty;

  /// Fires whenever [visible] or [replying] changes.
  final StreamController<void> _gates = StreamController.broadcast(sync: true);

  /// Fires when the app leaves the screen.
  final StreamController<void> _hidden = StreamController.broadcast(sync: true);
  Stream<void> get hidden => _hidden.stream;

  void _setVisible(bool v) {
    if (v == _visible) return;
    _visible = v;
    if (!v) {
      _pauses++;
      if (_backgroundRequest case final id?) unawaited(_native.cancel(id));
      _hidden.add(null);
    }
    _gates.add(null);
  }

  /// Completes once [ok] holds, checked whenever a gate changes.
  Future<void> _until(bool Function() ok) async {
    while (!ok()) {
      await _gates.stream.first;
    }
  }

  /// Completes once background work may run: Aithra is on screen and no
  /// reply is in progress. Housekeeping never keeps the process alive in
  /// the background, where Android may freeze or end it at any moment, and
  /// never takes the phone's time from a reply.
  Future<void> whenHousekeepingAllowed() =>
      _until(() => _visible && _holds.isEmpty);

  /// Completes once work someone may be waiting for can run: Aithra is on
  /// screen, or a reply is in progress (it keeps the process running).
  Future<void> whenAttended() => _until(() => _visible || _holds.isNotEmpty);

  /// Marks a reply the user is waiting for, from before it queues until
  /// [ReplyHold.end]. It ends background work, and while the user is away
  /// from Aithra it keeps the process running with a notification whose
  /// Stop calls [onStop].
  ReplyHold holdReply({required VoidCallback onStop}) {
    preemptBackground();
    final id = _nextHold++;
    _holds[id] = onStop;
    _gates.add(null);
    unawaited(_native.replyBegin(id));
    return ReplyHold._(this, id);
  }

  void _endHold(int id, String? convId, String? title) {
    _holds.remove(id);
    unawaited(_native.replyEnd(id, convId: convId, readyTitle: title));
    _gates.add(null);
  }

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
  /// [keepContext] is for chat replies: the engine keeps what it processed,
  /// so a next request that extends [turns] prefills only its new turn.
  Generation generate(
    List<EngineTurn> turns, {
    required int maxTokens,
    double temperature = 0.7,
    bool ignoreEos = false,
    bool keepContext = false,
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
          keepContext: keepContext,
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

  /// Completes once the work queued so far has run.
  Future<void> whenIdle() => _queue;

  /// Starts a run of background work (titles, memory suggestions,
  /// embedding) that ends for good at the first foreground load or
  /// generation after this call.
  BackgroundRun backgroundRun() => BackgroundRun._(this, _epoch);

  /// Runs [task] for a run begun at [epoch] once housekeeping is allowed
  /// and the engine is free. A task that ends empty (null) because the app
  /// left the screen meanwhile runs again once it is back; one preempted by
  /// foreground work gives null.
  Future<T?> _background<T extends Object>(
    int epoch,
    Future<T?> Function() task,
  ) async {
    while (true) {
      await whenHousekeepingAllowed();
      if (epoch != _epoch) return null;
      final pauses = _pauses;
      final out = await _exclusive(
        () async => epoch == _epoch && pauses == _pauses ? await task() : null,
      );
      if (out != null) return out;
      if (epoch != _epoch || pauses == _pauses) return null;
    }
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

/// Background steps that each wait until housekeeping is allowed (see
/// [EngineService.whenHousekeepingAllowed]) and the engine is free, and are
/// all skipped once foreground work has arrived since the run began; a
/// running generation step is cancelled, so the user never waits on one. A
/// step that fails throws, for the caller to report.
class BackgroundRun {
  BackgroundRun._(this._engine, this._epoch);

  final EngineService _engine;
  final int _epoch;

  bool get preempted => _epoch != _engine._epoch;

  /// Runs [task] when housekeeping is allowed and the engine is free; null
  /// if preempted first. A running task is not interrupted, so keep tasks
  /// short.
  Future<T?> step<T extends Object>(Future<T> Function() task) =>
      _engine._background(_epoch, task);

  /// A short generation on the already loaded model; null if preempted
  /// before or during it, or if no model is loaded (it never loads one).
  /// Interrupted by the app leaving the screen, it starts over once the
  /// app is back.
  Future<String?> generate(
    List<EngineTurn> turns, {
    required int maxTokens,
    double temperature = 0.1,
  }) {
    final e = _engine;
    return e._background(_epoch, () async {
      if (e._loadedKey == null) return null;
      final id = e._nextRequest++;
      final out = StringBuffer();
      final sub = e._native
          .eventsOf('token')
          .where((ev) => ev['requestId'] == id)
          .listen((ev) => out.write(ev['text']! as String));
      e._backgroundRequest = id;
      try {
        final m = await e._native.generate(
          requestId: id,
          turns: turns,
          maxTokens: maxTokens,
          temperature: temperature,
          ignoreEos: false,
          background: true,
        );
        // Foreground work of the other engine (the Ask sheet) cancels it
        // natively without touching this run's epoch.
        if (m['cancelled']! as bool) return null;
        return preempted ? null : out.toString();
      } finally {
        e._backgroundRequest = null;
        // Token events are posted before the method result on the same
        // main-thread queue, so all of them have arrived by now.
        await sub.cancel();
      }
    });
  }
}

/// A reply the user is waiting for (see [EngineService.holdReply]).
class ReplyHold {
  ReplyHold._(this._engine, this._id);

  final EngineService _engine;
  final int _id;

  /// Ends the hold. A reply that delivered something the user has not seen
  /// passes [readyTitle] (and [convId], the chat it went to): if the user
  /// is away, a "Reply ready" notification shows it.
  void end({String? convId, String? readyTitle}) =>
      _engine._endHold(_id, convId, readyTitle);
}
