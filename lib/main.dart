import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

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
import 'src/memory/memory_store.dart';
import 'src/memory/recall_index.dart';
import 'src/models/model_manager.dart';
import 'src/platform/native.dart';
import 'src/services.dart';
import 'src/voice/speech_service.dart';
import 'src/voice/tts_service.dart';

const String lockKey = 'aithra_app_lock_enabled';

/// Startup does only what the first frame needs: the secure-storage read
/// (lock flags + data key), the encrypted settings, and opening the chat
/// store. Models, memories, speech status and the engine warm-up all run
/// after the first frame.
Future<void> main() async {
  final startup = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();

  final storage = await CachedSecureStorage.load(
    const SecureStorageImpl(FlutterSecureStorage()),
  );
  final native = NativeBridge();
  final results = await Future.wait([
    LockController.readEnabled(storage, lockKey),
    LockController.readBiometricEnabled(storage, lockKey),
    AppearanceController.load(),
    DataKeyStore(storage).obtainKey(),
    native.storageInfo(),
  ]);
  final key = results[3] as Uint8List;
  final dataDir = (results[4] as Map<String, Object?>)['dataDir']! as String;
  final vault = Vault(dataDir, key);
  final settings = SettingsStore(vault);
  await Future.wait([settings.load(), native.dbOpen(key)]);

  final engine = EngineService(native);
  final models = ModelManager(native);
  final services = Services(
    native: native,
    engine: engine,
    models: models,
    settings: settings,
    memories: MemoryStore(vault),
    recall: RecallIndex(native: native, engine: engine, models: models),
    chats: ChatStore(native),
    assistant: Assistant(engine: engine, models: models, settings: settings),
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

Future<void> _afterFirstFrame(Services s) async {
  await Future.wait([s.models.refresh(), s.memories.load()]);
  s.assistant.warmUp();
}
