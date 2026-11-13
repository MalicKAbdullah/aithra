import 'package:flutter/foundation.dart';

import '../calibration/calibration.dart';
import 'vault.dart';

/// App preferences and per-model calibrations, persisted encrypted.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._vault);

  final Vault _vault;

  bool onboarded = false;
  String? selectedModelId;
  bool speakReplies = false;
  bool perfOverlay = false;
  final Map<String, Calibration> calibrations = {};

  /// Highest prompt tokens per UTF-8 byte each model (by id) has shown in a
  /// chat, for runtimes without a tokenizer.
  final Map<String, double> tokensPerByte = {};

  Future<void> load() async {
    final j = await _vault.read('settings') as Map<String, Object?>?;
    if (j == null) return;
    onboarded = j['onboarded'] as bool? ?? false;
    selectedModelId = j['selectedModel'] as String?;
    speakReplies = j['speakReplies'] as bool? ?? false;
    perfOverlay = j['perfOverlay'] as bool? ?? false;
    for (final c in (j['calibrations'] as List? ?? const [])) {
      final cal = Calibration.fromJson(Map<String, Object?>.from(c as Map));
      calibrations[cal.modelId] = cal;
    }
    for (final e in (j['tokensPerByte'] as Map? ?? const {}).entries) {
      tokensPerByte[e.key as String] = (e.value as num).toDouble();
    }
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    await _vault.write('settings', {
      'onboarded': onboarded,
      'selectedModel': selectedModelId,
      'speakReplies': speakReplies,
      'perfOverlay': perfOverlay,
      'calibrations': [for (final c in calibrations.values) c.toJson()],
      'tokensPerByte': tokensPerByte,
    });
  }

  Future<void> update(void Function(SettingsStore s) change) {
    change(this);
    return _save();
  }

  Future<void> putTokensPerByte(String modelId, double ratio) {
    tokensPerByte[modelId] = ratio;
    return _save();
  }

  Future<void> putCalibration(Calibration c) {
    calibrations[c.modelId] = c;
    return _save();
  }
}
