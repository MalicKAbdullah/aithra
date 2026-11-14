import 'dart:async';

import 'package:flutter/foundation.dart';

import 'speech_service.dart';

enum DictationPhase {
  idle,

  /// Asked for the microphone; the recognizer has not started yet.
  starting,
  listening,

  /// Stop was pressed; the recognizer is still delivering its last final.
  finishing,
}

/// How a dictation session ended.
enum DictationEnd {
  /// Done was pressed and the recognizer delivered everything it heard.
  done,

  /// Cancel was pressed; nothing heard is kept.
  cancelled,

  /// The recognizer stopped on an error ([SpeechService.errorCode]); what
  /// it finalised before the error is kept.
  failed,
}

/// One continuous dictation: the committed finals and the utterance in
/// progress, kept apart so the screen can show them differently and the
/// text field is written once per final instead of once per partial.
///
/// The session lasts until the recognizer reports `idle`, not until Stop:
/// Android delivers the final result of the utterance in progress after
/// `stopListening`, and dropping the listeners at Stop would lose it.
class Dictation {
  Dictation(this._speech);

  final SpeechService _speech;
  StreamSubscription<String>? _finals;
  bool _listening = false;

  final ValueNotifier<DictationPhase> phase = ValueNotifier(
    DictationPhase.idle,
  );

  /// Every final result of this session, joined.
  final ValueNotifier<String> committed = ValueNotifier('');

  /// The utterance being recognised; replaced by each partial result.
  final ValueNotifier<String> partial = ValueNotifier('');

  /// Called with [committed] after each final result.
  void Function(String committed)? onFinal;

  /// Called once per session when it ends, with what was committed.
  void Function(DictationEnd end, String committed)? onEnd;

  /// When listening started, for the elapsed time.
  final Stopwatch elapsed = Stopwatch();

  ValueListenable<double> get level => _speech.level;
  SpeechService get speech => _speech;
  bool get active => phase.value != DictationPhase.idle;

  /// Starts listening; false when the microphone was not granted.
  Future<bool> start() async {
    if (active) return true;
    committed.value = '';
    partial.value = '';
    phase.value = DictationPhase.starting;
    _finals = _speech.finals.listen(_onFinal);
    _speech.addListener(_onSpeech);
    _listening = false;
    if (!await _speech.start(continuous: true)) {
      _end(DictationEnd.failed);
      return false;
    }
    // Cancelled while the microphone permission was asked.
    if (phase.value != DictationPhase.starting) return true;
    _listening = true;
    elapsed
      ..reset()
      ..start();
    phase.value = DictationPhase.listening;
    return true;
  }

  /// Stops listening and keeps what was heard. The session ends at the
  /// recognizer's `idle`, after its last final result.
  Future<void> finish() async {
    if (phase.value != DictationPhase.listening) return;
    phase.value = DictationPhase.finishing;
    elapsed.stop();
    await _speech.stop();
  }

  /// Stops listening and discards what was heard.
  Future<void> cancel() async {
    if (!active) return;
    _end(DictationEnd.cancelled);
    await _speech.cancel();
  }

  void _onFinal(String text) {
    // Before this session's recognizer started, a final can only belong to
    // an earlier session (voice mode's, still winding down).
    if (!_listening) return;
    committed.value = joinSpeech(committed.value, text);
    partial.value = '';
    onFinal?.call(committed.value);
  }

  void _onSpeech() {
    if (!_listening) return;
    partial.value = _speech.partial;
    if (_speech.listening) return;
    _end(
      _speech.errorCode != null && phase.value == DictationPhase.listening
          ? DictationEnd.failed
          : DictationEnd.done,
    );
  }

  void _end(DictationEnd end) {
    _speech.removeListener(_onSpeech);
    unawaited(_finals?.cancel());
    _finals = null;
    _listening = false;
    elapsed.stop();
    partial.value = '';
    phase.value = DictationPhase.idle;
    onEnd?.call(end, committed.value);
  }

  void dispose() {
    if (active) {
      _speech.removeListener(_onSpeech);
      unawaited(_finals?.cancel());
      unawaited(_speech.cancel());
    }
    phase.dispose();
    committed.dispose();
    partial.dispose();
  }
}

/// [b] appended to [a] with one space between them.
String joinSpeech(String a, String b) =>
    a.trim().isEmpty ? b.trim() : '${a.trimRight()} ${b.trim()}';
