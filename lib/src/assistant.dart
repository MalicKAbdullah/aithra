import 'dart:async';

import 'package:flutter/widgets.dart';

import 'calibration/calibration.dart';
import 'data/settings_store.dart';
import 'engine/engine_service.dart';
import 'models/catalog.dart';
import 'models/download_state.dart';
import 'models/model_manager.dart';

/// Calibration progress for the UI.
class CalibrationStatus {
  const CalibrationStatus(this.model, this.done, this.total, this.label);

  final ModelSpec model;
  final int done;
  final int total;
  final String label;
}

/// Decides which model and backend answer the user, tunes new models to the
/// phone (auto-calibration), and keeps the engine warm: loaded in the
/// background after first frame, released after a long time in background.
class Assistant extends ChangeNotifier with WidgetsBindingObserver {
  Assistant({
    required this.engine,
    required this.models,
    required this.settings,
  }) {
    models.addListener(_onModelsChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  final EngineService engine;
  final ModelManager models;
  final SettingsStore settings;

  static const Duration releaseAfter = Duration(minutes: 5);

  CalibrationStatus? calibrating;
  Future<void>? _calibration;
  Timer? _releaseTimer;

  /// The selected model if it is on the phone, else the first one that is.
  ModelSpec? get activeModel {
    final selected = models.byId(settings.selectedModelId);
    if (selected != null && models.availability(selected) is Ready) {
      return selected;
    }
    final ready = models.readyModels;
    return ready.isEmpty ? null : ready.first;
  }

  /// A calibration that still matches the model file on disk.
  Calibration? calibrationFor(ModelSpec spec) {
    final c = settings.calibrations[spec.id];
    return c != null && c.fileSize == models.sizeOf(spec) ? c : null;
  }

  BackendOption? backendFor(ModelSpec spec) {
    final id = calibrationFor(spec)?.chosenBackend;
    return id == null ? null : BackendOption.byId(id);
  }

  void _onModelsChanged() {
    if (!models.loaded) return;
    final m = activeModel;
    if (m != null && calibrationFor(m) == null && _calibration == null) {
      unawaited(calibrate(m));
    }
    notifyListeners();
  }

  /// Runs calibration for [spec] in the background and remembers the result.
  Future<void> calibrate(ModelSpec spec) {
    final existing = _calibration;
    if (existing != null) return existing;
    final path = models.pathOf(spec);
    if (path == null) return Future.value();
    final run = () async {
      try {
        final result = await CalibrationRunner(engine).run(
          spec,
          path,
          models.sizeOf(spec),
          onProgress: (done, total, label) {
            calibrating = CalibrationStatus(spec, done, total, label);
            notifyListeners();
          },
        );
        await settings.putCalibration(result);
      } finally {
        calibrating = null;
        _calibration = null;
        notifyListeners();
      }
    }();
    _calibration = run;
    return run;
  }

  /// Loads the active model on its chosen backend. Waits for a running
  /// calibration first; returns null when there is no usable model.
  Future<(ModelSpec, BackendOption)?> prepare() async {
    if (_calibration != null) await _calibration;
    final spec = activeModel;
    if (spec == null) return null;
    final path = models.pathOf(spec)!;
    var backend = backendFor(spec);
    if (backend == null) {
      await calibrate(spec);
      backend = backendFor(spec);
      if (backend == null) return null;
    }
    await engine.ensureLoaded(spec, path, backend);
    return (spec, backend);
  }

  /// Loads the model ahead of the first message, ignoring failures (they
  /// surface when the user sends).
  void warmUp() {
    final spec = activeModel;
    if (spec == null || _calibration != null) return;
    final backend = backendFor(spec);
    if (backend == null || engine.isLoaded(spec, backend)) return;
    unawaited(prepare().then((_) {}, onError: (_) {}));
  }

  Future<void> select(ModelSpec spec) async {
    await settings.update((s) => s.selectedModelId = spec.id);
    if (calibrationFor(spec) == null) {
      unawaited(calibrate(spec));
    } else {
      warmUp();
    }
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _releaseTimer?.cancel();
      _releaseTimer = Timer(releaseAfter, () {
        if (_calibration == null) unawaited(engine.release());
      });
    } else if (state == AppLifecycleState.resumed) {
      _releaseTimer?.cancel();
      unawaited(models.refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    models.removeListener(_onModelsChanged);
    super.dispose();
  }
}
