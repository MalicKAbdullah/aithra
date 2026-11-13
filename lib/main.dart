import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';
import 'dart:ui';

import 'package:core_lock/core_lock.dart';
import 'package:core_storage/core_storage.dart';
import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'src/app.dart';
import 'src/assistant.dart';
import 'src/chat/chat_store.dart';
import 'src/data/settings_store.dart';
import 'src/data/vault.dart';
import 'src/engine/engine_service.dart';
import 'src/memory/memory_curator.dart';
import 'src/memory/memory_store.dart';
import 'src/memory/recall_index.dart';
import 'src/models/model_manager.dart';
import 'src/platform/native.dart';
import 'src/services.dart';
import 'src/ui/screens/report_screen.dart';
import 'src/voice/speech_service.dart';
import 'src/voice/tts_service.dart';

const String lockKey = 'aithra_app_lock_enabled';

/// A crash report from the previous run is shown before anything touches
/// the database or the Keystore, so a crash in either can still be
/// reported. Startup failures render their error instead of leaving the
/// splash on screen.
Future<void> main() async {
  final startup = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();
  final native = NativeBridge();
  reportErrorsTo(native);

  final lastCrash = await native.crashRead();
  if (lastCrash != null) {
    final proceed = Completer<void>();
    runApp(
      ReportApp(
        home: ReportScreen.lastCrash(
          native: native,
          report: lastCrash,
          onContinue: proceed.complete,
        ),
      ),
    );
    await proceed.future;
    await native.crashClear();
  }

  await _launch(native, startup);
}

Future<void> _launch(NativeBridge native, Stopwatch startup) async {
  final Services services;
  try {
    services = await start(native);
  } on DataKeyLost {
    runApp(
      ReportApp(
        home: DataLostScreen(
          onErase: () async {
            await native.eraseData();
            await _launch(native, startup);
          },
        ),
      ),
    );
    return;
  } catch (error, stack) {
    runApp(
      ReportApp(
        home: ReportScreen.startupFailed(
          native: native,
          report: '$error\n\n$stack',
        ),
      ),
    );
    return;
  }
  developer.log(
    'ready to paint ${startup.elapsedMilliseconds} ms',
    name: 'aithra.startup',
  );

  runApp(ServicesScope(services: services, child: const AithraApp()));

  WidgetsBinding.instance.addPostFrameCallback((_) {
    developer.log(
      'first frame ${startup.elapsedMilliseconds} ms',
      name: 'aithra.startup',
    );
    unawaited(_afterFirstFrame(services));
  });
}

/// Sends every Dart error to the crash report shown on the next launch.
void reportErrorsTo(NativeBridge native) {
  // A report that cannot be written must not raise a new error, which would
  // come straight back here.
  void record(String title, Object error, StackTrace? stack) =>
      native.crashRecord(title, [error, ?stack].join('\n')).ignore();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    record('Flutter error', details.exceptionAsString(), details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    record('Uncaught Dart error', error, stack);
    return false;
  };
}

/// Does only what the first frame needs: the secure-storage read (lock
/// flags + data key), the encrypted settings, and opening the chat store.
/// Models, memories, speech status and the engine warm-up all run after the
/// first frame.
Future<Services> start(NativeBridge native) async {
  final storage = await CachedSecureStorage.load(
    const SecureStorageImpl(FlutterSecureStorage()),
  );
  final results = await Future.wait([
    LockController.readEnabled(storage, lockKey),
    LockController.readBiometricEnabled(storage, lockKey),
    AppearanceController.load(),
    DataKeyStore(storage).obtainKey(dataExists: native.hasData),
    native.dataDir(),
    native.runsLlama(),
  ]);
  final key = results[3] as Uint8List;
  final vault = Vault(results[4] as String, key);
  final settings = SettingsStore(vault);
  await Future.wait([settings.load(), native.dbOpen(key)]);

  final engine = EngineService(native);
  final models = ModelManager(native, runsLlama: results[5] as bool);
  final recall = RecallIndex(native: native, engine: engine, models: models);
  final memories = MemoryStore(vault);
  final services = Services(
    native: native,
    engine: engine,
    models: models,
    settings: settings,
    memories: memories,
    recall: recall,
    chats: ChatStore(native, searchMessages: recall.search),
    assistant: Assistant(engine: engine, models: models, settings: settings),
    keeper: MemoryKeeper(
      native: native,
      memories: memories,
      models: models,
      settings: settings,
    ),
    lock: LockController(
      deviceAuth: LocalAuthDeviceAuth(),
      hasher: const Argon2PasswordHasher(),
      storage: storage,
      clock: DateTime.now,
      storageKey: lockKey,
      appName: 'Aithra',
      enabled: results[0] as bool,
      biometricEnabled: results[1] as bool,
    ),
    appearance: results[2] as AppearanceController,
    speech: SpeechService(native),
    tts: TtsService(native),
  );
  // The first page of chats is tiny and decrypts natively; loading it now
  // means the list paints with content on the first frame.
  await services.chats.refresh();
  return services;
}

Future<void> _afterFirstFrame(Services s) async {
  await Future.wait([s.models.refresh(), s.memories.load()]);
  s.assistant.warmUp();
}
