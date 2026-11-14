import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chat/chat_session.dart';
import '../data/settings_store.dart';
import '../platform/native.dart';
import 'sentence_splitter.dart';
import 'tts_service.dart';

/// Reads text aloud with the user's voice settings: one thing at a time,
/// sentence by sentence, each reply in its own language.
///
/// - [read] / [toggle] speak a finished text, e.g. a message's Read aloud
///   button keyed by the message.
/// - [follow] speaks a reply while it is still being written; voice mode and
///   the "Read replies aloud" setting ([followReply]) use it.
///
/// [reading] is the key of what is being read, so a button can show Stop.
class ReadAloud extends ChangeNotifier {
  ReadAloud({
    required TtsService tts,
    required NativeBridge native,
    required SettingsStore settings,
  }) : _tts = tts,
       _native = native,
       _settings = settings;

  final TtsService _tts;
  final NativeBridge _native;
  final SettingsStore _settings;

  Object? _key;
  int _run = 0;

  /// The key passed to [read] or [follow] for what is being read; null
  /// when nothing is.
  Object? get reading => _key;

  bool isReading(Object key) => _key == key;

  /// Reads [markdown] aloud, replacing anything being read. Completes when
  /// it has been spoken or stopped. [language] overrides the settings and
  /// the detected language.
  Future<void> read(Object key, String markdown, {String? language}) {
    final reader = follow(key)
      .._language = language == null ? null : Future.value(language);
    reader.finish(markdown);
    return reader.done;
  }

  /// [read] when [key] is not being read, otherwise [stop].
  Future<void> toggle(Object key, String markdown) =>
      isReading(key) ? stop() : read(key, markdown);

  /// Starts reading a reply that is still being written, replacing anything
  /// being read. Feed it with [ReplyReader.add] and end it with
  /// [ReplyReader.finish].
  ReplyReader follow(Object key) {
    final run = ++_run;
    if (_key != null) unawaited(_tts.stop());
    _key = key;
    notifyListeners();
    return ReplyReader._(this, run);
  }

  /// Reads the reply [session] is about to start or is writing aloud as it
  /// streams.
  void followReply(ChatSession session) {
    final reader = follow(session);
    var replying = session.busy;
    void onText() => reader.add(session.streaming.value);
    late final VoidCallback onPhase;
    onPhase = () {
      if (session.busy) {
        replying = true;
        return;
      }
      if (!replying) return;
      session.streaming.removeListener(onText);
      session.removeListener(onPhase);
      reader.finish(session.error == null ? session.lastReply : '');
    };
    session.streaming.addListener(onText);
    session.addListener(onPhase);
  }

  /// Stops reading at once.
  Future<void> stop() async {
    _run++;
    if (_key == null) return;
    _key = null;
    notifyListeners();
    await _tts.stop();
  }

  void _finished(int run) {
    if (run != _run) return;
    _key = null;
    notifyListeners();
  }
}

/// One reply being read aloud by [ReadAloud.follow].
class ReplyReader {
  ReplyReader._(this._owner, this._run);

  final ReadAloud _owner;
  final int _run;
  final SentenceSplitter _splitter = SentenceSplitter();
  final Completer<void> _done = Completer();
  int _seen = 0;
  bool _finishing = false;

  /// Sentences are spoken in order through this chain; the first one waits
  /// for the reply's language.
  Future<void> _chain = Future.value();
  Future<String?>? _language;

  /// Completes when everything has been spoken, or the reading was
  /// stopped or replaced.
  Future<void> get done => _done.future;

  /// Whether any sentence has been queued for speaking.
  bool started = false;

  bool get _current => _owner._run == _run;

  /// Takes the reply's whole text so far and speaks the sentences it
  /// completes.
  void add(String textSoFar) {
    if (!_current || _finishing || textSoFar.length <= _seen) return;
    final chunk = textSoFar.substring(_seen);
    _seen = textSoFar.length;
    _speak(_splitter.add(chunk));
  }

  /// Takes the reply's final text, speaks the rest of it and completes
  /// [done] once it has been spoken.
  void finish(String fullText) {
    add(fullText);
    _finishing = true;
    _speak(_splitter.flush());
    _chain = _chain.then((_) async {
      if (_current) await _owner._tts.idle;
      _owner._finished(_run);
    });
    unawaited(_chain.whenComplete(_complete));
  }

  void _complete() {
    if (!_done.isCompleted) _done.complete();
  }

  void _speak(List<String> sentences) {
    if (sentences.isEmpty) return;
    started = true;
    // The first sentence decides the reply's language: replies keep one
    // language, and waiting for more would delay the first word.
    final settings = _owner._settings;
    _language ??= settings.ttsLanguage != null
        ? Future.value(settings.ttsLanguage)
        : _owner._native.detectLanguage(sentences.first);
    final language = _language!;
    for (final s in sentences) {
      _chain = _chain.then((_) async {
        final tag = await language;
        if (!_current) return;
        await _owner._tts.say(
          s,
          language: tag,
          voice: settings.ttsVoice,
          rate: settings.ttsRate,
        );
      });
    }
  }
}
