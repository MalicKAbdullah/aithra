import 'dart:async';
import 'dart:convert';

import 'package:core_lock/core_lock.dart';
import 'package:core_storage/core_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../assistant.dart';
import '../chat/chat_models.dart';
import '../chat/chat_session.dart';
import '../chat/context_builder.dart';
import '../chat/templates.dart';
import '../data/settings_store.dart';
import '../data/vault.dart';
import '../engine/engine_service.dart';
import '../engine/run_metrics.dart';
import '../models/model_manager.dart';
import '../platform/native.dart';
import '../services.dart';

/// Why the sheet cannot answer yet, and what to do about it.
enum AskBlocker {
  /// Aithra has never been opened: no data key, no model.
  setup,

  /// No model on the phone.
  noModel,

  /// The model has not been tuned for this phone.
  untuned,
}

enum AskPhase { idle, preparing, streaming, done }

/// The Ask sheet's state: the selection, the chosen request and its
/// streaming answer. It loads what it needs in its own engine, since the
/// app may not be running; the lock gate covers the sheet until unlocked.
class AskController extends ChangeNotifier {
  AskController(this.native, this.selection, {required this.readOnly});

  final NativeBridge native;
  final String selection;

  /// The calling app does not take a replacement.
  final bool readOnly;

  LockController? lock;
  AskBlocker? blocker;
  String? error;

  late final SettingsStore _settings;
  late final EngineService _engine;
  late final Assistant _assistant;
  bool _ready = false;

  /// The language Translate writes in: the phone's, until the user picks.
  String language = '';
  List<({String tag, String name})> languages = const [];

  PromptTemplate? template;
  AskPhase phase = AskPhase.idle;
  final StreamingText answer = StreamingText();
  RunMetrics? _metrics;
  String _prompt = '';
  Generation? _generation;

  /// Loads the lock first, so the sheet is gated before anything of
  /// Aithra's shows, then the data key, settings and model list, and
  /// starts loading the model.
  Future<void> start() async {
    final storage = await CachedSecureStorage.load(
      const SecureStorageImpl(FlutterSecureStorage()),
    );
    final flags = await Future.wait([
      LockController.readEnabled(storage, lockKey),
      LockController.readBiometricEnabled(storage, lockKey),
    ]);
    lock = LockController(
      deviceAuth: LocalAuthDeviceAuth(),
      hasher: const Argon2PasswordHasher(),
      storage: storage,
      clock: DateTime.now,
      storageKey: lockKey,
      appName: 'Aithra',
      enabled: flags[0],
      biometricEnabled: flags[1],
    );
    notifyListeners();
    if (!await native.hasData()) {
      blocker = AskBlocker.setup;
      notifyListeners();
      return;
    }
    final Uint8List key;
    try {
      key = await DataKeyStore(storage).obtainKey(dataExists: native.hasData);
    } on DataKeyLost {
      blocker = AskBlocker.setup;
      notifyListeners();
      return;
    }
    final results = await Future.wait([
      native.dataDir(),
      native.runsLlama(),
      native.languages(),
    ]);
    _settings = SettingsStore(Vault(results[0] as String, key));
    await Future.wait([_settings.load(), native.dbOpen(key)]);
    languages = results[2] as List<({String tag, String name})>;
    language = languages.first.name;
    _engine = EngineService(native);
    final models = ModelManager(native, runsLlama: results[1] as bool);
    await models.refresh();
    _assistant = Assistant(
      engine: _engine,
      models: models,
      settings: _settings,
      tunes: false,
    );
    _ready = true;
    final spec = _assistant.activeModel;
    if (!_settings.onboarded) {
      blocker = AskBlocker.setup;
    } else if (spec == null) {
      blocker = AskBlocker.noModel;
    } else if (_assistant.calibrationFor(spec) == null) {
      blocker = AskBlocker.untuned;
    } else {
      _assistant.warmUp();
    }
    notifyListeners();
  }

  bool get canAsk => _ready && blocker == null;

  void setLanguage(String name) {
    language = name;
    notifyListeners();
  }

  /// Answers [chosen] for the selection; [question] is the Ask… text.
  Future<void> ask(PromptTemplate chosen, {String question = ''}) async {
    if (!canAsk) return;
    await stop();
    template = chosen;
    _prompt = question.isEmpty
        ? chosen.prompt(selection, language: language)
        : askAbout(question, selection);
    error = null;
    answer.reset();
    phase = AskPhase.preparing;
    notifyListeners();
    try {
      final prepared = await _assistant.prepare();
      final (spec, _) = prepared!;
      final contextSize = _engine.contextSize!;
      final system = buildSystemPrompt(
        SystemContext(
          now: DateTime.now(),
          aboutUser: _settings.aboutUser,
          replyStyle: _settings.replyStyle,
        ),
      );
      final counted = await _engine.countTokens([
        EngineTurn('system', system),
        EngineTurn('user', _prompt),
      ]);
      final ratio = _assistant.tokensPerByte(spec);
      Future<int> cost(String text) async => counted.counts == null
          ? estimateTokens(text, ratio)
          : (await _engine.countTokens([
              EngineTurn('user', text),
            ])).counts!.single;
      final systemTokens =
          counted.counts?.first ?? estimateTokens(system, ratio);
      final message = await fitMessage(
        PromptMessage(
          seq: 0,
          isUser: true,
          text: _prompt,
          tokens: counted.counts?[1] ?? estimateTokens(_prompt, ratio),
        ),
        room:
            contextSize -
            ChatSession.replyTokens -
            systemTokens -
            (counted.overhead ?? 0),
        cost: cost,
      );
      if (template != chosen) return;
      final g = _generation = _engine.generate([
        EngineTurn('system', system),
        EngineTurn('user', message.text),
      ], maxTokens: ChatSession.replyTokens);
      final sub = g.text.listen((chunk) {
        // A stopped answer's last tokens can still arrive after the next
        // request has begun.
        if (template != chosen) return;
        if (phase != AskPhase.streaming) {
          phase = AskPhase.streaming;
          notifyListeners();
        }
        answer.add(chunk);
      });
      _metrics = await g.done;
      await sub.cancel();
    } on PlatformException catch (e) {
      error = e.message ?? e.code;
    } on StateError catch (e) {
      error = e.message;
    } finally {
      _generation = null;
      if (template == chosen) {
        phase = AskPhase.done;
        notifyListeners();
      }
    }
  }

  Future<void> stop() async => _generation?.cancel();

  /// The answer as it stands, including any tail not yet shown.
  String get result => answer.full.trim();

  Future<void> copy() => Clipboard.setData(ClipboardData(text: result));

  Future<void> replace() => native.askReplace(result);

  Future<void> close() => native.askClose();

  /// Saves the request and answer as a new chat and opens it in the app.
  Future<void> continueInChat() async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final now = DateTime.now().millisecondsSinceEpoch;
    await native.dbCreateConversation(
      id,
      titleFrom('${template!.label}: $selection'),
      now,
    );
    await native.dbAddMessage(
      convId: id,
      role: 'user',
      content: _prompt,
      images: const [],
      stats: null,
      now: now,
    );
    await native.dbAddMessage(
      convId: id,
      role: 'model',
      content: result,
      images: const [],
      stats: _metrics == null ? null : jsonEncode(_metrics!.toJson()),
      now: now + 1,
    );
    await native.askOpenChat(id);
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
