import 'package:flutter/services.dart';

import '../engine/engine_service.dart';
import '../engine/run_metrics.dart';
import '../models/catalog.dart';
import '../platform/native.dart';
import 'correctness.dart';

/// Decode budget of a speed run. Prefill is the fixed [speedPrompt].
const int speedDecodeTokens = 128;
const int probeMaxTokens = 24;

/// The outcome of trying one backend for one model.
class BackendResult {
  const BackendResult({
    required this.backendId,
    this.loadMs,
    this.loadPeakRssMb,
    this.speed,
    this.answers = const [],
    this.error,
  });

  factory BackendResult.fromJson(Map<String, Object?> j) => BackendResult(
    backendId: j['backend']! as String,
    loadMs: (j['loadMs'] as num?)?.toDouble(),
    loadPeakRssMb: (j['loadPeakRssMb'] as num?)?.toDouble(),
    speed: j['speed'] == null
        ? null
        : RunMetrics.fromMap(Map<String, Object?>.from(j['speed']! as Map)),
    answers: [for (final a in j['answers']! as List) a as String],
    error: j['error'] as String?,
  );

  final String backendId;
  final double? loadMs;
  final double? loadPeakRssMb;
  final RunMetrics? speed;

  /// Raw replies to [probes], in order.
  final List<String> answers;
  final String? error;

  int get correct {
    var n = 0;
    for (var i = 0; i < answers.length && i < probes.length; i++) {
      if (probes[i].passes(answers[i])) n++;
    }
    return n;
  }

  bool get allCorrect => error == null && correct == probes.length;

  double? get peakRssMb {
    final values = [loadPeakRssMb, speed?.peakRssMb].whereType<double>();
    return values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b);
  }

  Map<String, Object?> toJson() => {
    'backend': backendId,
    'loadMs': loadMs,
    'loadPeakRssMb': loadPeakRssMb,
    'speed': speed?.toJson(),
    'answers': answers,
    'error': error,
  };
}

/// Calibration of one model file on this phone.
class Calibration {
  const Calibration({
    required this.modelId,
    required this.fileSize,
    required this.results,
    required this.chosenBackend,
    required this.finishedAt,
  });

  factory Calibration.fromJson(Map<String, Object?> j) => Calibration(
    modelId: j['modelId']! as String,
    fileSize: j['fileSize']! as int,
    results: [
      for (final r in j['results']! as List)
        BackendResult.fromJson(Map<String, Object?>.from(r as Map)),
    ],
    chosenBackend: j['chosen'] as String?,
    finishedAt: DateTime.fromMillisecondsSinceEpoch(j['finishedAt']! as int),
  );

  final String modelId;

  /// Re-calibrate when the file changes.
  final int fileSize;
  final List<BackendResult> results;

  /// Null when no backend could load the model.
  final String? chosenBackend;
  final DateTime finishedAt;

  bool get chosenIsCorrect =>
      results.any((r) => r.backendId == chosenBackend && r.allCorrect);

  Map<String, Object?> toJson() => {
    'modelId': modelId,
    'fileSize': fileSize,
    'results': [for (final r in results) r.toJson()],
    'chosen': chosenBackend,
    'finishedAt': finishedAt.millisecondsSinceEpoch,
  };
}

/// The fastest backend that answered every probe correctly. When none did,
/// the one with the most correct answers (ties: fastest), so the app still
/// works and Settings → Performance shows the warning. Null when nothing
/// loaded.
String? pickBackend(List<BackendResult> results) {
  final loaded = results.where((r) => r.error == null).toList();
  if (loaded.isEmpty) return null;
  double speed(BackendResult r) => r.speed?.decodeTps ?? 0;
  loaded.sort((a, b) {
    final byCorrect = b.correct.compareTo(a.correct);
    return byCorrect != 0 ? byCorrect : speed(b).compareTo(speed(a));
  });
  return loaded.first.backendId;
}

/// Progress callback: (backends finished, backends total, current label).
typedef CalibrationProgress = void Function(int done, int total, String label);

/// Tries every candidate backend of a model: load, answer the probes with
/// greedy decoding, then a fixed-size speed run.
class CalibrationRunner {
  CalibrationRunner(this._engine);

  final EngineService _engine;

  Future<Calibration> run(
    ModelSpec spec,
    String path,
    int fileSize, {
    required CalibrationProgress onProgress,
  }) async {
    final results = <BackendResult>[];
    for (final backend in spec.backends) {
      onProgress(results.length, spec.backends.length, backend.label);
      results.add(await _tryBackend(spec, path, backend));
    }
    onProgress(results.length, spec.backends.length, '');
    return Calibration(
      modelId: spec.id,
      fileSize: fileSize,
      results: results,
      chosenBackend: pickBackend(results),
      finishedAt: DateTime.now(),
    );
  }

  Future<BackendResult> _tryBackend(
    ModelSpec spec,
    String path,
    BackendOption backend,
  ) async {
    LoadResult? load;
    try {
      // Unload first so every backend's load time is measured cold.
      await _engine.release();
      load = await _engine.ensureLoaded(spec, path, backend);
      final answers = <String>[];
      for (final probe in probes) {
        final g = _engine.generate(
          [EngineTurn('user', probe.prompt)],
          maxTokens: probeMaxTokens,
          temperature: 0,
        );
        final text = await g.text.join();
        await g.done;
        answers.add(text);
      }
      final speedRun = _engine.generate(
        const [EngineTurn('user', speedPrompt)],
        maxTokens: speedDecodeTokens,
        temperature: 0,
        ignoreEos: true,
      );
      await speedRun.text.drain<void>();
      final speed = await speedRun.done;
      return BackendResult(
        backendId: backend.id,
        loadMs: load?.loadMs,
        loadPeakRssMb: load?.peakRssMb,
        speed: speed,
        answers: answers,
      );
    } catch (e) {
      return BackendResult(
        backendId: backend.id,
        loadMs: load?.loadMs,
        error: e is PlatformException ? (e.message ?? e.code) : '$e',
      );
    }
  }
}
