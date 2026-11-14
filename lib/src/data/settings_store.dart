import 'package:flutter/foundation.dart';

import '../calibration/calibration.dart';
import 'prompt_shortcut.dart';
import 'vault.dart';

/// App preferences and per-model calibrations, persisted encrypted.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._vault);

  final Vault _vault;

  bool onboarded = false;
  String? selectedModelId;

  /// Read each reply aloud as it is written.
  bool speakReplies = false;
  bool perfOverlay = false;

  /// Custom instructions: what the user wants Aithra to know about them and
  /// how it should respond. Both go into every chat's system prompt.
  String aboutUser = '';
  String replyStyle = '';

  /// Whether Aithra keeps and uses long-term memories about the user.
  bool memoryEnabled = true;

  /// Voice mode shows what was heard and the reply; off, only the orb.
  bool voiceTranscript = true;

  /// The language replies are read aloud in (BCP 47), or null to read each
  /// reply in the language it is written in.
  String? ttsLanguage;

  /// The voice replies are read in (`NativeBridge.ttsVoices`), or null for
  /// the engine's default voice of the language.
  String? ttsVoice;

  /// TextToSpeech rate; 1 is normal.
  double ttsRate = 1;

  /// The chips on a new chat and in the Ask Aithra sheet, in order.
  List<PromptShortcut> promptShortcuts = defaultPromptShortcuts;

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
    aboutUser = j['aboutUser'] as String? ?? '';
    replyStyle = j['replyStyle'] as String? ?? '';
    memoryEnabled = j['memoryEnabled'] as bool? ?? true;
    voiceTranscript = j['voiceTranscript'] as bool? ?? true;
    ttsLanguage = j['ttsLanguage'] as String?;
    ttsVoice = j['ttsVoice'] as String?;
    ttsRate = (j['ttsRate'] as num? ?? 1).toDouble();
    if (j['promptShortcuts'] case final List<Object?> list) {
      promptShortcuts = [
        for (final p in list)
          PromptShortcut.fromJson(Map<String, Object?>.from(p! as Map)),
      ];
    }
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
      'aboutUser': aboutUser,
      'replyStyle': replyStyle,
      'memoryEnabled': memoryEnabled,
      'voiceTranscript': voiceTranscript,
      'ttsLanguage': ttsLanguage,
      'ttsVoice': ttsVoice,
      'ttsRate': ttsRate,
      'promptShortcuts': [for (final p in promptShortcuts) p.toJson()],
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
