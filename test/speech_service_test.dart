import 'dart:async';
import 'dart:convert';

import 'package:aithra/src/data/settings_store.dart';
import 'package:aithra/src/data/vault.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:aithra/src/voice/speech_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Kotlin speech bridge as Dart sees it: events are pushed by the test,
/// status answers come from [status].
class FakeSpeechNative extends NativeBridge {
  FakeSpeechNative._(this._events)
    : super(channel: const MethodChannel('fake'), events: _events.stream);
  factory FakeSpeechNative() =>
      FakeSpeechNative._(StreamController<Object?>.broadcast());

  final StreamController<Object?> _events;
  Map<String, Object?> status = {
    'onDevice': true,
    'language': 'en-US',
    'model': 'missing',
  };
  bool canDownload = true;
  int statusChecks = 0;
  int downloads = 0;
  int settingsOpened = 0;

  Future<void> emit(Map<String, Object?> e) async {
    push(e);
    await pumpEventQueue();
  }

  /// For fake-time tests, which deliver it with `tester.pump()`.
  void push(Map<String, Object?> e) => _events.add(e);

  @override
  Future<Map<String, Object?>> speechStatus() async {
    statusChecks++;
    return status;
  }

  @override
  Future<bool> downloadSpeechModel() async {
    downloads++;
    return canDownload;
  }

  @override
  Future<void> openVoiceSettings() async => settingsOpened++;

  @override
  Future<String> requestMicrophone() async => 'granted';

  @override
  Future<void> startListening({required bool continuous}) async {}
}

Map<String, Object?> download(String kind, [Map<String, Object?>? extra]) => {
  'type': 'speechDownload',
  'kind': kind,
  'language': 'en-US',
  'report': {
    'installed': <Object?>[],
    'pending': <Object?>[],
    'supported': <Object?>['en-US'],
  },
  ...?extra,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSpeechNative native;
  late SpeechService speech;

  setUp(() {
    native = FakeSpeechNative();
    speech = SpeechService(
      native,
      pollEvery: const Duration(milliseconds: 5),
      pollFor: const Duration(milliseconds: 60),
    );
  });

  tearDown(() => speech.dispose());

  Future<void> languageError(int code, {String sent = 'en-JP'}) => native.emit({
    'type': 'speech',
    'kind': 'error',
    't': 0,
    'onDevice': true,
    'code': code,
    'language': sent,
    'report': {
      'installed': <Object?>['en-US'],
      'pending': <Object?>[],
      'supported': <Object?>['en-US', 'ja-JP'],
    },
  });

  group('language errors', () {
    test('keep the tag sent and the recognizer languages to copy', () async {
      await languageError(13);
      expect(speech.languageMissing, isTrue);
      expect(
        speech.report.toString(),
        'Language sent: en-JP\n'
        'Installed: en-US\n'
        'Downloading: none\n'
        'Downloadable: en-US, ja-JP',
      );
    });

    test('check the status, which decides the action', () async {
      await languageError(13);
      expect(native.statusChecks, 1);
      expect(speech.modelNotice!.action, SpeechAction.download);

      native.status = {...native.status, 'model': 'unsupported'};
      await speech.checkStatus();
      expect(speech.modelNotice!.action, SpeechAction.openSpeechSettings);
      expect(speech.modelNotice!.error, isTrue);
    });

    test('clear once the status reports the model installed', () async {
      native.status = {...native.status, 'model': 'installed'};
      await languageError(12);
      expect(speech.languageMissing, isFalse);
      expect(speech.modelNotice, isNull);
    });
  });

  group('download', () {
    test('shows the request until Android answers', () async {
      await speech.downloadLanguage();
      expect(native.downloads, 1);
      expect(speech.download.phase, DownloadPhase.requesting);
      expect(speech.modelNotice!.busy, isTrue);
    });

    test('ignores taps while a request is running', () async {
      await speech.downloadLanguage();
      await speech.downloadLanguage();
      expect(native.downloads, 1);
    });

    test('opens speech settings when the phone cannot download', () async {
      native.canDownload = false;
      await speech.downloadLanguage();
      expect(native.settingsOpened, 1);
      expect(speech.download.phase, DownloadPhase.idle);
    });

    test('progress fills the bar', () async {
      await native.emit(download('progress', {'percent': 42}));
      expect(speech.download.phase, DownloadPhase.downloading);
      expect(speech.modelNotice!.progress, 0.42);
      expect(speech.modelNotice!.text, contains('42%'));
    });

    test('success clears the language error and re-checks status', () async {
      await languageError(13);
      final checks = native.statusChecks;
      native.status = {...native.status, 'model': 'installed'};
      await native.emit(download('success'));
      expect(speech.download.phase, DownloadPhase.done);
      expect(speech.languageMissing, isFalse);
      expect(native.statusChecks, checks + 1);
      expect(speech.model, SpeechModel.installed);

      await speech.start(continuous: false);
      expect(speech.download.phase, DownloadPhase.idle);
      expect(speech.modelNotice, isNull);
    });

    test('scheduled points at speech settings', () async {
      await native.emit(download('scheduled'));
      final notice = speech.modelNotice!;
      expect(notice.text, contains('later'));
      expect(notice.action, SpeechAction.openSpeechSettings);
      expect(notice.error, isFalse);
    });

    test('an error shows Android\'s reason and speech settings', () async {
      await native.emit(download('error', {'code': 2}));
      final notice = speech.modelNotice!;
      expect(speech.download.errorCode, 2);
      expect(notice.text, startsWith(downloadErrorMessage(2)));
      expect(notice.action, SpeechAction.openSpeechSettings);
      expect(notice.error, isTrue);
    });

    testWidgets('an unreported request polls until the model arrives', (
      tester,
    ) async {
      // Built in the fake-time zone, so its poll timer runs on fake time.
      final speech = SpeechService(
        native,
        pollEvery: const Duration(milliseconds: 5),
        pollFor: const Duration(milliseconds: 60),
      );
      addTearDown(speech.dispose);
      native.push(download('requested'));
      await tester.pump();
      expect(speech.download.phase, DownloadPhase.waiting);
      native.status = {...native.status, 'model': 'installed'};
      await tester.pump(const Duration(milliseconds: 5));
      expect(speech.download.phase, DownloadPhase.done);
      final checks = native.statusChecks;
      await tester.pump(const Duration(milliseconds: 50));
      expect(native.statusChecks, checks, reason: 'polling stopped');
    });

    testWidgets('an unreported request that never arrives fails visibly', (
      tester,
    ) async {
      // Built in the fake-time zone, so its poll timer runs on fake time.
      final speech = SpeechService(
        native,
        pollEvery: const Duration(milliseconds: 5),
        pollFor: const Duration(milliseconds: 60),
      );
      addTearDown(speech.dispose);
      native.push(download('requested'));
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        expect(speech.download.phase, DownloadPhase.waiting);
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(native.statusChecks, 12);
      await tester.pump(const Duration(milliseconds: 5));
      expect(speech.download.phase, DownloadPhase.failed);
      expect(speech.download.errorCode, isNull);
      expect(speech.modelNotice!.action, SpeechAction.openSpeechSettings);
      expect(speech.modelNotice!.error, isTrue);
    });
  });

  test('a status event with the model pending says so', () async {
    await languageError(13);
    await native.emit({
      'type': 'speechStatus',
      'onDevice': true,
      'language': 'en-US',
      'model': 'pending',
    });
    expect(speech.language, 'en-US');
    expect(speech.modelNotice!.busy, isTrue);
  });

  void backgroundAndReturn(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  testWidgets('returning to the app re-checks a missing model', (tester) async {
    await speech.checkStatus();
    final checks = native.statusChecks;
    backgroundAndReturn(tester);
    expect(native.statusChecks, checks + 1);

    native.status = {...native.status, 'model': 'installed'};
    await tester.runAsync(speech.checkStatus);
    backgroundAndReturn(tester);
    expect(native.statusChecks, checks + 2, reason: 'installed: no check');
  });

  group('voice transcript setting', () {
    test('is on until turned off, and stays off', () async {
      final vault = MemVault();
      final first = SettingsStore(vault);
      await first.load();
      expect(first.voiceTranscript, isTrue);
      await first.update((s) => s.voiceTranscript = false);

      final reopened = SettingsStore(vault);
      await reopened.load();
      expect(reopened.voiceTranscript, isFalse);
    });
  });
}

class MemVault extends Vault {
  MemVault() : super('/dev/null', Uint8List(32));
  final Map<String, Object?> docs = {};

  @override
  Future<Object?> read(String name) async => docs[name];

  @override
  Future<void> write(String name, Object? value) async =>
      docs[name] = jsonDecode(jsonEncode(value));
}
