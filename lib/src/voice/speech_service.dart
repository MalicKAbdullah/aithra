import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/native.dart';

/// `SpeechRecognizer.ERROR_*` codes that mean the on-device language pack
/// is missing.
const Set<int> languageMissingErrors = {12, 13};

String speechErrorMessage(int code) => switch (code) {
  1 || 2 => 'Network error',
  3 => 'Microphone error',
  4 => 'Speech service error',
  5 => 'Speech recognition was interrupted',
  8 => 'Speech recognizer is busy',
  9 => 'Microphone permission is needed',
  11 => 'Speech service is unavailable',
  12 || 13 => 'The speech model for your language is not on this phone',
  _ => 'Speech recognition failed ($code)',
};

/// Latencies of one utterance, from the recognizer's own event times.
class SpeechMetrics {
  const SpeechMetrics({
    this.firstPartialMs,
    this.finalMs,
    required this.onDevice,
  });

  /// From the start of speech to the first partial result.
  final int? firstPartialMs;

  /// From the end of speech to the final result.
  final int? finalMs;
  final bool onDevice;
}

/// Computes [SpeechMetrics] from recognizer events (`t` = elapsed ms).
class SpeechClock {
  int? _begin;
  int? _end;
  int? _firstPartial;
  int? _final;
  bool onDevice = false;

  void reset() => _begin = _end = _firstPartial = _final = null;

  void on(String kind, int t) {
    switch (kind) {
      case 'begin':
        _begin ??= t;
      case 'partial':
        _firstPartial ??= t;
      case 'end':
        _end = t;
      case 'final':
        _final = t;
    }
  }

  SpeechMetrics get metrics => SpeechMetrics(
    firstPartialMs: _begin != null && _firstPartial != null
        ? _firstPartial! - _begin!
        : null,
    finalMs: _end != null && _final != null ? _final! - _end! : null,
    onDevice: onDevice,
  );
}

/// Android's built-in recognizer: live partial text, final results, and
/// continuous dictation. One listener at a time.
class SpeechService extends ChangeNotifier {
  SpeechService(this._native) {
    _native.eventsOf('speech').listen(_onEvent);
    _native.eventsOf('speechStatus').listen((e) {
      languageInstalled = e['languageInstalled'] as bool?;
      notifyListeners();
    });
  }

  final NativeBridge _native;
  final SpeechClock _clock = SpeechClock();
  final StreamController<String> _finals = StreamController.broadcast();

  bool listening = false;
  bool continuous = false;

  /// Text of the utterance in progress.
  String partial = '';
  double level = 0;
  int? errorCode;
  bool? onDeviceAvailable;
  bool? languageInstalled;
  SpeechMetrics? lastMetrics;

  /// Each final result.
  Stream<String> get finals => _finals.stream;

  bool get languageMissing =>
      errorCode != null && languageMissingErrors.contains(errorCode);

  Future<void> checkStatus() async {
    final s = await _native.speechStatus();
    onDeviceAvailable = s['onDevice'] as bool?;
    final installed = s['languageInstalled'];
    languageInstalled = installed is bool ? installed : null;
    notifyListeners();
  }

  Future<bool> start({required bool continuous}) async {
    if (!await _native.requestMicrophone()) {
      errorCode = 9;
      notifyListeners();
      return false;
    }
    unawaited(HapticFeedback.mediumImpact());
    errorCode = null;
    partial = '';
    this.continuous = continuous;
    listening = true;
    _clock.reset();
    notifyListeners();
    await _native.startListening(continuous: continuous);
    return true;
  }

  Future<void> stop() async {
    unawaited(HapticFeedback.lightImpact());
    await _native.stopListening();
  }

  Future<void> cancel() async {
    listening = false;
    partial = '';
    notifyListeners();
    await _native.cancelListening();
  }

  Future<void> downloadLanguage() async {
    if (!await _native.downloadSpeechModel()) {
      await _native.openVoiceSettings();
    }
  }

  Future<void> openSettings() => _native.openVoiceSettings();

  void _onEvent(Map<String, Object?> e) {
    final kind = e['kind']! as String;
    _clock.onDevice = e['onDevice'] as bool? ?? false;
    _clock.on(kind, e['t']! as int);
    switch (kind) {
      case 'level':
        level = (e['rms']! as num).toDouble();
      case 'partial':
        partial = e['text']! as String;
      case 'final':
        final text = e['text']! as String;
        lastMetrics = _clock.metrics;
        _clock.reset();
        partial = '';
        if (text.isNotEmpty) _finals.add(text);
      case 'idle':
        listening = false;
      case 'error':
        listening = false;
        errorCode = e['code']! as int;
    }
    notifyListeners();
  }
}
