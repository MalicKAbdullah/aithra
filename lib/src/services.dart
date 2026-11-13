import 'package:core_lock/core_lock.dart';
import 'package:core_theme/core_theme.dart';
import 'package:flutter/widgets.dart';

import 'assistant.dart';
import 'chat/chat_store.dart';
import 'data/settings_store.dart';
import 'engine/engine_service.dart';
import 'memory/memory_store.dart';
import 'models/model_manager.dart';
import 'platform/native.dart';
import 'voice/speech_service.dart';
import 'voice/tts_service.dart';

/// Everything the screens use, created once in main().
class Services {
  Services({
    required this.native,
    required this.engine,
    required this.models,
    required this.settings,
    required this.memories,
    required this.chats,
    required this.assistant,
    required this.lock,
    required this.appearance,
    required this.speech,
    required this.tts,
  });

  final NativeBridge native;
  final EngineService engine;
  final ModelManager models;
  final SettingsStore settings;
  final MemoryStore memories;
  final ChatStore chats;
  final Assistant assistant;
  final LockController lock;
  final AppearanceController appearance;
  final SpeechService speech;
  final TtsService tts;
}

class ServicesScope extends InheritedWidget {
  const ServicesScope({
    required this.services,
    required super.child,
    super.key,
  });

  final Services services;

  static Services of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ServicesScope>()!.services;

  @override
  bool updateShouldNotify(ServicesScope oldWidget) => false;
}

extension ServicesX on BuildContext {
  Services get services => ServicesScope.of(this);
}
