import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/native.dart';

/// Android's built-in TextToSpeech. Sentences queue in order; [idle]
/// completes once everything queued has been spoken (or stopped).
class TtsService extends ChangeNotifier {
  TtsService(this._native) {
    _native.eventsOf('tts').listen((e) {
      final kind = e['kind']! as String;
      if (kind == 'done' || kind == 'error' || kind == 'stopped') {
        _pending.remove(e['id']);
        if (_pending.isEmpty) _settle();
      }
    });
  }

  final NativeBridge _native;
  final Set<String> _pending = {};
  Completer<void>? _idle;
  int _next = 0;

  bool get speaking => _pending.isNotEmpty;

  Future<void> say(String sentence) async {
    final id = 'u${_next++}';
    _pending.add(id);
    notifyListeners();
    await _native.speak(sentence, id);
  }

  /// Completes when the queue is empty.
  Future<void> get idle {
    if (_pending.isEmpty) return Future.value();
    return (_idle ??= Completer<void>()).future;
  }

  Future<void> stop() async {
    _pending.clear();
    _settle();
    await _native.stopSpeaking();
  }

  void _settle() {
    _idle?.complete();
    _idle = null;
    notifyListeners();
  }
}
