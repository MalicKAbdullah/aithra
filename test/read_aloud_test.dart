import 'dart:async';
import 'dart:convert';

import 'package:aithra/src/chat/context_builder.dart';
import 'package:aithra/src/data/prompt_shortcut.dart';
import 'package:aithra/src/data/settings_store.dart';
import 'package:aithra/src/data/vault.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:aithra/src/voice/read_aloud.dart';
import 'package:aithra/src/voice/tts_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MemVault extends Vault {
  MemVault() : super('/dev/null', Uint8List(32));
  final Map<String, Object?> docs = {};

  @override
  Future<Object?> read(String name) async => docs[name];

  @override
  Future<void> write(String name, Object? value) async =>
      docs[name] = jsonDecode(jsonEncode(value));
}

/// TextToSpeech that records what it was asked to say and finishes each
/// utterance when the test says so.
class FakeTts extends NativeBridge {
  FakeTts._(this._events)
    : super(channel: const MethodChannel('fake'), events: _events.stream);
  factory FakeTts() => FakeTts._(StreamController<Object?>.broadcast());

  final StreamController<Object?> _events;
  final List<({String text, String id, String? language, double rate})> spoken =
      [];
  String? detected = 'fr';
  final List<String> detectedFor = [];
  int stops = 0;

  @override
  Future<void> speak(
    String text,
    String id, {
    String? language,
    String? voice,
    double rate = 1,
  }) async => spoken.add((text: text, id: id, language: language, rate: rate));

  @override
  Future<String?> detectLanguage(String text) async {
    detectedFor.add(text);
    return detected;
  }

  @override
  Future<void> stopSpeaking() async => stops++;

  void finishAll() {
    for (final s in spoken) {
      _events.add({'type': 'tts', 'kind': 'done', 'id': s.id});
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTts native;
  late SettingsStore settings;
  late ReadAloud read;

  setUp(() {
    native = FakeTts();
    settings = SettingsStore(MemVault());
    read = ReadAloud(
      tts: TtsService(native),
      native: native,
      settings: settings,
    );
  });

  test(
    'a streamed reply is spoken by sentence in its detected language',
    () async {
      settings.ttsRate = 1.25;
      final reader = read.follow('m1');
      expect(read.reading, 'm1');
      reader.add('Bonjour à tous. Comment');
      await pumpEventQueue();
      expect(native.spoken.map((s) => s.text), ['Bonjour à tous.']);
      reader.add('Bonjour à tous. Comment allez-vous? Très');
      reader.finish('Bonjour à tous. Comment allez-vous? Très bien.');
      await pumpEventQueue();
      expect(native.spoken.map((s) => s.text), [
        'Bonjour à tous.',
        'Comment allez-vous?',
        'Très bien.',
      ]);
      // Detected once, from the first sentence.
      expect(native.detectedFor, ['Bonjour à tous.']);
      expect(native.spoken.every((s) => s.language == 'fr'), isTrue);
      expect(native.spoken.every((s) => s.rate == 1.25), isTrue);
      native.finishAll();
      await reader.done;
      expect(read.reading, isNull);
    },
  );

  test('a chosen language is used without detecting', () async {
    settings.ttsLanguage = 'en-GB';
    unawaited(read.read('m', 'One. Two.'));
    await pumpEventQueue();
    expect(native.detectedFor, isEmpty);
    expect(native.spoken.map((s) => s.language).toSet(), {'en-GB'});
  });

  test('toggle stops what is being read; a new read replaces it', () async {
    unawaited(read.read('a', 'First message. It is long.'));
    await pumpEventQueue();
    expect(read.isReading('a'), isTrue);
    unawaited(read.read('b', 'Second.'));
    await pumpEventQueue();
    expect(read.isReading('b'), isTrue);
    expect(native.stops, 1);
    await read.toggle('b', 'Second.');
    expect(read.reading, isNull);
    expect(native.stops, 2);
  });

  test('voice mode asks for short spoken replies without markup', () {
    final spoken = buildSystemPrompt(
      SystemContext(now: DateTime(2026), spoken: true),
    );
    final written = buildSystemPrompt(SystemContext(now: DateTime(2026)));
    expect(spoken, contains('read aloud'));
    expect(spoken, isNot(contains('Use Markdown')));
    expect(written, contains('Use Markdown'));
    expect(
      buildSystemPrompt(
        SystemContext(
          now: DateTime(2026),
          spoken: true,
          recalled: ['x'],
        ).shed()!,
      ),
      contains('read aloud'),
    );
  });

  test('voice settings and prompt shortcuts persist', () async {
    final vault = MemVault();
    final a = SettingsStore(vault);
    expect(a.promptShortcuts, defaultPromptShortcuts);
    await a.update(
      (s) => s
        ..ttsLanguage = 'es-ES'
        ..ttsVoice = 'es-es-x-eea-local'
        ..ttsRate = 1.5
        ..promptShortcuts = const [PromptShortcut('Fix', 'Fix the grammar: ')],
    );
    final b = SettingsStore(vault);
    await b.load();
    expect(b.ttsLanguage, 'es-ES');
    expect(b.ttsVoice, 'es-es-x-eea-local');
    expect(b.ttsRate, 1.5);
    expect(b.promptShortcuts, const [
      PromptShortcut('Fix', 'Fix the grammar: '),
    ]);
    await b.update((s) => s.promptShortcuts = const []);
    final c = SettingsStore(vault);
    await c.load();
    expect(c.promptShortcuts, isEmpty);
  });
}
