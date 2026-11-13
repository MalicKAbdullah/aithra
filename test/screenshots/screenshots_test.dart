// Renders review screenshots of Aithra at Pixel 8 size (1080x2400 @ 2.625)
// with a fake native bridge and seeded in-memory data:
//
//   SCREENSHOT_DIR=/path/to/dir flutter test test/screenshots
//
// Without SCREENSHOT_DIR the scenarios are skipped, so the normal test run
// never writes files.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aithra/src/app.dart';
import 'package:aithra/src/assistant.dart';
import 'package:aithra/src/calibration/calibration.dart';
import 'package:aithra/src/chat/chat_store.dart';
import 'package:aithra/src/data/settings_store.dart';
import 'package:aithra/src/data/vault.dart';
import 'package:aithra/src/engine/engine_service.dart';
import 'package:aithra/src/engine/run_metrics.dart';
import 'package:aithra/src/memory/memory_store.dart';
import 'package:aithra/src/memory/recall_index.dart';
import 'package:aithra/src/models/model_manager.dart';
import 'package:aithra/src/platform/native.dart';
import 'package:aithra/src/services.dart';
import 'package:aithra/src/ui/screens/chat_screen.dart';
import 'package:aithra/src/ui/screens/memories_screen.dart';
import 'package:aithra/src/ui/screens/models_screen.dart';
import 'package:aithra/src/ui/screens/performance_screen.dart';
import 'package:aithra/src/ui/screens/settings_screen.dart';
import 'package:aithra/src/ui/screens/voice_mode_screen.dart';
import 'package:aithra/src/ui/widgets/aithra_mark.dart';
import 'package:aithra/src/voice/speech_service.dart';
import 'package:aithra/src/voice/tts_service.dart';
import 'package:core_lock/core_lock.dart';
import 'package:core_storage/core_storage.dart';
import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';

const _dpr = 2.625;
const _phys = Size(1080, 2400);
const _statusBar = 32.0;
const _navBar = 24.0;
final _rootKey = GlobalKey();

final String? _outDir = Platform.environment['SCREENSHOT_DIR'];

// -- Fakes ------------------------------------------------------------------

class MemVault extends Vault {
  MemVault() : super('/dev/null', Uint8List(32));
  final Map<String, Object?> docs = {};

  @override
  Future<Object?> read(String name) async => docs[name];

  @override
  Future<void> write(String name, Object? value) async =>
      docs[name] = jsonDecode(jsonEncode(value));
}

class MemStorage implements ISecureStorage {
  final Map<String, String> _v = {};
  @override
  Future<void> write({required String key, required String value}) async =>
      _v[key] = value;
  @override
  Future<String?> read({required String key}) async => _v[key];
  @override
  Future<void> delete({required String key}) async => _v.remove(key);
  @override
  Future<void> deleteAll() async => _v.clear();
  @override
  Future<Map<String, String>> readAll() async => Map.of(_v);
}

class FakeNative extends NativeBridge {
  FakeNative._(this._events)
    : super(channel: const MethodChannel('fake'), events: _events.stream);
  factory FakeNative() => FakeNative._(StreamController<Object?>.broadcast());

  final StreamController<Object?> _events;

  final List<Map<String, Object?>> conversations = [];
  final Map<String, List<Map<String, Object?>>> messages = {};
  final Map<String, Uint8List> images = {};
  List<Map<String, Object?>> files = [];
  List<Map<String, Object?>> downloads = [];
  int _nextMessageId = 1000;
  int? lastRequest;

  void emit(Map<String, Object?> e) => _events.add(e);

  void tokens(String text) =>
      emit({'type': 'token', 'requestId': lastRequest, 'text': text});

  @override
  Future<Map<String, Object?>> load({
    required String runtime,
    required String path,
    required String backend,
    required int? threads,
    required bool vision,
    required int? maxTokens,
  }) async => {'contextSize': 4096, 'loadMs': 3400.0, 'peakRssMb': 2200.0};

  @override
  Future<Map<String, Object?>> generate({
    required int requestId,
    required List<EngineTurn> turns,
    required int maxTokens,
    required double temperature,
    required bool ignoreEos,
  }) {
    lastRequest = requestId;
    // Never completes: the reply stays mid-stream for the screenshot.
    return Completer<Map<String, Object?>>().future;
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> unload() async {}

  List<Map<String, Object?>> _sorted() => [...conversations]
    ..sort((a, b) {
      final p = (b['pinned']! as bool ? 1 : 0) - (a['pinned']! as bool ? 1 : 0);
      return p != 0
          ? p
          : (b['updated']! as int).compareTo(a['updated']! as int);
    });

  @override
  Future<void> dbOpen(Uint8List key) async {}

  @override
  Future<List<Map<String, Object?>>> dbConversations(
    int offset,
    int limit,
  ) async => _sorted().skip(offset).take(limit).map(_withPreview).toList();

  /// Mirrors ChatDb: the latest message rides along as the preview.
  Map<String, Object?> _withPreview(Map<String, Object?> c) {
    final list = messages[c['id']] ?? const [];
    if (list.isEmpty) return Map.of(c);
    final last = list.reduce(
      (a, b) => (a['seq']! as int) > (b['seq']! as int) ? a : b,
    );
    return {...c, 'preview': last['content'], 'previewRole': last['role']};
  }

  @override
  Future<Map<String, Object?>?> dbConversation(String id) async {
    final c = conversations.where((c) => c['id'] == id).firstOrNull;
    return c == null ? null : _withPreview(c);
  }

  @override
  Future<void> dbCreateConversation(String id, String title, int now) async {
    conversations.add(conv(id, title, now));
    messages[id] = [];
  }

  @override
  Future<void> dbUpdateConversation(
    String id,
    Map<String, Object?> fields,
  ) async {
    conversations.where((c) => c['id'] == id).firstOrNull?.addAll(fields);
  }

  @override
  Future<void> dbDeleteConversation(String id) async =>
      conversations.removeWhere((c) => c['id'] == id);

  @override
  Future<List<Map<String, Object?>>> dbMessages(
    String convId,
    int beforeSeq,
    int limit,
  ) async {
    final list =
        (messages[convId] ?? [])
            .where((m) => (m['seq']! as int) < beforeSeq)
            .toList()
          ..sort((a, b) => (b['seq']! as int).compareTo(a['seq']! as int));
    return list.take(limit).map(Map.of).toList();
  }

  @override
  Future<List<Map<String, Object?>>> dbMessageRange(
    String convId,
    int fromSeq,
    int toSeq,
  ) async {
    final list = (messages[convId] ?? []).where((m) {
      final s = m['seq']! as int;
      return s >= fromSeq && s < toSeq;
    }).toList()..sort((a, b) => (a['seq']! as int).compareTo(b['seq']! as int));
    return list.map(Map.of).toList();
  }

  @override
  Future<Map<String, Object?>> dbAddMessage({
    required String convId,
    required String role,
    required String content,
    required List<String> images,
    required String? stats,
    required int now,
  }) async {
    final list = messages.putIfAbsent(convId, () => []);
    final seq = list.isEmpty
        ? 0
        : list.map((m) => m['seq']! as int).reduce(math.max) + 1;
    final id = _nextMessageId++;
    list.add(msg(id, seq, role, content, now, images: images, stats: stats));
    return {'id': id, 'seq': seq};
  }

  @override
  Future<void> dbUpdateMessage(int id, String content, String? stats) async {}
  @override
  Future<void> dbTruncate(String convId, int fromSeq) async {}
  @override
  Future<void> dbPutImage(String id, Uint8List jpeg) async => images[id] = jpeg;
  @override
  Future<Uint8List?> dbImage(String id, {required bool thumb}) async =>
      images[id];
  @override
  Future<List<Map<String, Object?>>> dbSearch(String query, int limit) async =>
      [];
  @override
  Future<List<Map<String, Object?>>> dbRecall(
    String modelPath,
    String query,
    String? excludeConv,
    int limit,
  ) async => [];

  @override
  Future<int> dbIndexVectors(String modelPath, int limit) async => 0;

  @override
  Future<List<Map<String, Object?>>> dbSearchMessages(
    String modelPath,
    String query,
    int limit,
  ) async => [];

  @override
  Future<({int indexed, int total})> dbVectorStatus() async =>
      (indexed: 0, total: 0);

  @override
  Future<({List<int>? counts, int? overhead})> countTokens(
    List<EngineTurn> turns,
  ) async => (counts: null, overhead: null);

  @override
  Future<void> dbSetTokens(Map<int, int> counts, String model) async {}

  @override
  Future<Map<String, Object?>> deviceInfo() async => {
    'manufacturer': 'Google',
    'model': 'Pixel 8',
    'androidRelease': '16',
    'sdkInt': 36,
    'socManufacturer': 'Google',
    'socModel': 'Tensor G3',
    'totalRamMb': 7812,
    'appVersion': '0.1.0',
    'appBuild': '1',
  };

  @override
  Future<Map<String, Object?>> storageInfo() async => {
    'dataDir': '/data/user/0/app.aithra/files',
    'freeBytes': 41200000000,
  };

  @override
  Future<List<Map<String, Object?>>> listModelFiles() async =>
      files.map(Map.of).toList();
  @override
  Future<List<Map<String, Object?>>> queryDownloads() async =>
      downloads.map(Map.of).toList();

  @override
  Future<bool> requestMicrophone() async => true;
  @override
  Future<Map<String, Object?>> speechStatus() async => {
    'onDevice': true,
    'languageInstalled': true,
  };
  @override
  Future<void> startListening({required bool continuous}) async {}
  @override
  Future<void> stopListening() async {}
  @override
  Future<void> cancelListening() async {}
  @override
  Future<void> speak(String text, String id) async {}
  @override
  Future<void> stopSpeaking() async {}
}

Map<String, Object?> conv(
  String id,
  String title,
  int updated, {
  bool pinned = false,
  String? draft,
  int count = 2,
  String? preview,
  String previewRole = 'model',
}) => {
  'id': id,
  'title': title,
  'created': updated - 3600000,
  'updated': updated,
  'pinned': pinned,
  'summary': null,
  'summarizedUpto': 0,
  'draft': draft,
  'scroll': 0.0,
  'messageCount': count,
  'preview': preview,
  'previewRole': previewRole,
};

Map<String, Object?> msg(
  int id,
  int seq,
  String role,
  String content,
  int created, {
  List<String> images = const [],
  String? stats,
}) => {
  'id': id,
  'seq': seq,
  'role': role,
  'content': content,
  'images': images,
  'created': created,
  'stats': stats,
};

// -- Seed data --------------------------------------------------------------

const _e2bSize = 2588147712;
const _e4bSize = 3659530240;
const _qwenSize = 1214873856;

const _codeQuestion =
    'I have a folder of holiday photos named IMG_4021.jpg and so on. Can you '
    'write a Python script that renames them by the date they were taken?';

const _codeAnswer = '''
Sure. This reads each photo's **EXIF date** and renames it to `YYYY-MM-DD_HHMMSS.jpg`, so they sort in the order they were taken.

```python
from pathlib import Path
from PIL import Image

def taken_at(path):
    raw = Image.open(path).getexif().get(306)  # "2024:07:14 18:32:05"
    if raw is None:
        return None
    return raw.replace(":", "-", 2).replace(" ", "_").replace(":", "")

for photo in sorted(Path("photos").glob("*.jpg")):
    stamp = taken_at(photo)
    if stamp:
        photo.rename(photo.with_name(f"{stamp}.jpg"))
```

A few things to know:
- Install Pillow first: `pip install pillow`
- Photos without a date are left as they are
- Try it on a *copy* of the folder the first time''';

const _followUp =
    'Two photos were taken in the same second, so one got overwritten. '
    'Can you fix that?';

const _streamed =
    'Good catch. `rename` silently replaces an existing file on macOS and '
    'Linux, so the second photo wins. Add a counter whenever the name is '
    'already taken:\n\n```python\ndef unique(target):\n    n = 1\n'
    '    while target.exists():\n        target = target.with_stem(';

const _plantQuestion = 'What plant is this, and how often should I water it?';

const _plantAnswer = '''
That looks like a **Monstera deliciosa**, often called a Swiss cheese plant. The split, glossy leaves give it away.

### Watering
- Water when the top 3–5 cm of soil is dry, roughly **every 1–2 weeks**
- Water less in winter, when it grows slowly
- Yellowing lower leaves usually mean *too much* water

> Keep it out of harsh afternoon sun. Bright, indirect light is ideal.''';

Calibration _e2bCalibration() => Calibration(
  modelId: 'gemma4-e2b',
  fileSize: _e2bSize,
  chosenBackend: 'gpu',
  finishedAt: DateTime.now().subtract(const Duration(days: 2)),
  results: const [
    BackendResult(
      backendId: 'gpu',
      loadMs: 3420,
      loadPeakRssMb: 2210,
      speed: RunMetrics(
        promptTokens: 512,
        prefillMs: 402,
        ttftMs: 455,
        decodeTokens: 128,
        decodeMs: 5333,
        peakRssMb: 2384,
      ),
      answers: ['42', 'Paris', '72'],
    ),
    BackendResult(
      backendId: 'gpu_fp32',
      loadMs: 3980,
      loadPeakRssMb: 2480,
      speed: RunMetrics(
        promptTokens: 512,
        prefillMs: 640,
        ttftMs: 690,
        decodeTokens: 128,
        decodeMs: 7111,
        peakRssMb: 2650,
      ),
      answers: ['42', 'Paris', '72'],
    ),
    BackendResult(
      backendId: 'cpu',
      loadMs: 2150,
      loadPeakRssMb: 1890,
      speed: RunMetrics(
        promptTokens: 512,
        prefillMs: 4100,
        ttftMs: 4180,
        decodeTokens: 128,
        decodeMs: 12190,
        peakRssMb: 1960,
      ),
      answers: ['42', 'Paris', '27'],
    ),
  ],
);

Calibration _qwenCalibration() => Calibration(
  modelId: 'qwen35-2b-q4',
  fileSize: _qwenSize,
  chosenBackend: 'cpu6',
  finishedAt: DateTime.now().subtract(const Duration(days: 1)),
  results: const [
    BackendResult(
      backendId: 'cpu4',
      loadMs: 1310,
      loadPeakRssMb: 1420,
      speed: RunMetrics(
        promptTokens: 498,
        prefillMs: 3020,
        ttftMs: 3090,
        decodeTokens: 128,
        decodeMs: 9846,
        peakRssMb: 1510,
      ),
      answers: ['42', 'Paris', '72'],
    ),
    BackendResult(
      backendId: 'cpu6',
      loadMs: 1290,
      loadPeakRssMb: 1430,
      speed: RunMetrics(
        promptTokens: 498,
        prefillMs: 2410,
        ttftMs: 2470,
        decodeTokens: 128,
        decodeMs: 8258,
        peakRssMb: 1530,
      ),
      answers: ['42', 'Paris', '72'],
    ),
  ],
);

/// A procedurally drawn "photo" of a monstera in a pot.
Future<Uint8List> _plantPhoto() async {
  const w = 600.0, h = 600.0;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, w, h),
    Paint()
      ..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(w, h), [
        const Color(0xFFF3E7D3),
        const Color(0xFFD9C3A0),
      ]),
  );
  // Window light.
  canvas.drawRect(
    const Rect.fromLTWH(380, 0, 220, 330),
    Paint()..color = const Color(0x55FFFFFF),
  );
  // Table.
  canvas.drawRect(
    const Rect.fromLTWH(0, 470, w, 130),
    Paint()..color = const Color(0xFF8A6A4A),
  );
  // Leaves.
  final rnd = math.Random(7);
  for (var i = 0; i < 9; i++) {
    final angle = -math.pi / 2 + (i - 4) * 0.32 + rnd.nextDouble() * 0.1;
    final len = 170 + rnd.nextDouble() * 70;
    final base = const Offset(300, 400);
    final tip = base + Offset(math.cos(angle), math.sin(angle)) * len;
    canvas.drawLine(
      base,
      tip,
      Paint()
        ..color = const Color(0xFF3F6B2E)
        ..strokeWidth = 5,
    );
    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    canvas.rotate(angle + math.pi / 2);
    final leaf = Path()..addOval(const Rect.fromLTWH(-62, -70, 124, 120));
    canvas.drawPath(
      leaf,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(-60, -60),
          const Offset(60, 60),
          [const Color(0xFF4E8C3A), const Color(0xFF2C5A22)],
        ),
    );
    final slit = Paint()
      ..color = const Color(0xFFE6D5B8)
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    for (var s = -2; s <= 2; s++) {
      if (s == 0) continue;
      canvas.drawLine(
        Offset(s * 26.0, -10),
        Offset(s * 58.0, -20 + s.abs() * 6.0),
        slit,
      );
    }
    canvas.drawLine(
      const Offset(0, -60),
      const Offset(0, 40),
      Paint()
        ..color = const Color(0xFF9CC37E)
        ..strokeWidth = 3,
    );
    canvas.restore();
  }
  // Pot.
  final pot = Path()
    ..moveTo(220, 400)
    ..lineTo(380, 400)
    ..lineTo(360, 520)
    ..lineTo(240, 520)
    ..close();
  canvas.drawPath(pot, Paint()..color = const Color(0xFFC0623A));
  canvas.drawRect(
    const Rect.fromLTWH(212, 392, 176, 22),
    Paint()..color = const Color(0xFFA8522F),
  );
  final image = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void _seedChats(FakeNative n, Uint8List photo) {
  final now = DateTime.now().millisecondsSinceEpoch;
  const min = 60000, hour = 3600000, day = 86400000;
  n.conversations.addAll([
    conv(
      'trip',
      'Lake District weekend: route and packing list',
      now - 2 * day,
      pinned: true,
      count: 14,
      preview:
          'Day two: Catbells to Maiden Moor is about 8 km. Pack waterproofs, '
          'a warm layer and plenty of snacks.',
    ),
    conv(
      'code',
      'Python script to rename photos by date',
      now - 12 * min,
      count: 2,
    ),
    conv('plant', 'What plant is this?', now - 3 * hour),
    conv(
      'interest',
      'Explain compound interest simply',
      now - day - hour,
      preview:
          'You earn interest on your interest. £1,000 at 5% becomes £1,050, '
          'then £1,102.50 the next year.',
    ),
    conv(
      'landlord',
      'Polite reply to my landlord about the boiler',
      now - 3 * day,
      draft: 'Can you make it a bit firmer, but still friendly?',
      preview: 'Hi Alex, the boiler has stopped heating water again.',
    ),
    conv(
      'sourdough',
      'Why is my sourdough starter not rising?',
      now - 9 * day,
      preview: 'Mine is flat after two days and smells a bit like nail polish.',
      previewRole: 'user',
    ),
    conv(
      'gift',
      'Birthday gift ideas for a 10-year-old',
      now - 23 * day,
      preview:
          'A beginner telescope, a build-your-own robot kit or a book series '
          'like Percy Jackson.',
    ),
  ]);
  n.messages['code'] = [
    msg(1, 0, 'user', _codeQuestion, now - 14 * min),
    msg(
      2,
      1,
      'model',
      _codeAnswer,
      now - 13 * min,
      stats: jsonEncode(
        const RunMetrics(
          promptTokens: 210,
          prefillMs: 180,
          ttftMs: 240,
          decodeTokens: 220,
          decodeMs: 9100,
        ).toJson(),
      ),
    ),
  ];
  n.images['img-plant'] = photo;
  n.messages['plant'] = [
    msg(3, 0, 'user', _plantQuestion, now - 3 * hour, images: ['img-plant']),
    msg(4, 1, 'model', _plantAnswer, now - 3 * hour),
  ];
}

void _seedModels(FakeNative n) {
  n.files = [
    {
      'path': '/models/gemma-4-E2B-it.litertlm',
      'name': 'gemma-4-E2B-it.litertlm',
      'size': _e2bSize,
    },
    {
      'path': '/models/Qwen3.5-2B-Q4_0.gguf',
      'name': 'Qwen3.5-2B-Q4_0.gguf',
      'size': _qwenSize,
    },
  ];
  n.downloads = [
    {
      'id': 12,
      'fileName': 'gemma-4-E4B-it.litertlm',
      'status': 2,
      'reason': 0,
      'downloaded': (_e4bSize * 0.41).round(),
      'total': _e4bSize,
    },
    {
      'id': 9,
      'fileName': 'gemma-3-1b-it-Q4_0.gguf',
      'status': 16,
      'reason': 1004,
      'downloaded': 0,
      'total': 721918496,
    },
  ];
}

// -- Harness ----------------------------------------------------------------

class Harness {
  Harness(this.native, this.services);
  final FakeNative native;
  final Services services;
}

Future<Harness> _build(
  WidgetTester tester, {
  required Brightness brightness,
  bool onboarded = true,
  bool withModels = true,
}) async {
  tester.view
    ..physicalSize = _phys
    ..devicePixelRatio = _dpr
    ..padding = const FakeViewPadding(
      top: _statusBar * _dpr,
      bottom: _navBar * _dpr,
    )
    ..viewPadding = const FakeViewPadding(
      top: _statusBar * _dpr,
      bottom: _navBar * _dpr,
    );
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('fake'),
    (_) async => null,
  );

  final native = FakeNative();
  late Uint8List photo;
  await tester.runAsync(() async => photo = await _plantPhoto());
  _seedChats(native, photo);
  if (withModels) _seedModels(native);

  SharedPreferences.setMockInitialValues({});
  final appearance = await AppearanceController.load();
  await appearance.setMode(
    brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
  );

  final vault = MemVault();
  vault.docs['memories'] = [
    for (final (i, t) in const [
      "User's name is Sam",
      'Lives in Manchester',
      'Prefers metric units and 24-hour time',
      'Is vegetarian',
      'Is learning Python for work',
      'Daughter Ava turns 10 in March',
      'Allergic to penicillin',
    ].indexed)
      {
        'id': '$i',
        'text': t,
        'created': DateTime.now()
            .subtract(Duration(days: i * 3))
            .millisecondsSinceEpoch,
      },
  ];
  final settings = SettingsStore(vault)
    ..onboarded = onboarded
    ..selectedModelId = withModels ? 'gemma4-e2b' : null;
  if (withModels) {
    settings.calibrations['gemma4-e2b'] = _e2bCalibration();
    settings.calibrations['qwen35-2b-q4'] = _qwenCalibration();
  }
  final memories = MemoryStore(vault);
  await memories.load();

  final engine = EngineService(native);
  final models = ModelManager(native);
  final recall = RecallIndex(native: native, engine: engine, models: models);
  final services = Services(
    native: native,
    engine: engine,
    models: models,
    settings: settings,
    memories: memories,
    recall: recall,
    chats: ChatStore(native, searchMessages: recall.search),
    assistant: Assistant(engine: engine, models: models, settings: settings),
    lock: LockController(
      deviceAuth: const UnavailableDeviceAuth(),
      hasher: const Argon2PasswordHasher(),
      storage: MemStorage(),
      clock: DateTime.now,
      storageKey: 'aithra_lock',
      appName: 'Aithra',
    ),
    appearance: appearance,
    speech: SpeechService(native),
    tts: TtsService(native),
  );
  await services.chats.refresh();
  await models.refresh();

  await tester.pumpWidget(
    RepaintBoundary(
      key: _rootKey,
      child: Stack(
        textDirection: TextDirection.ltr,
        children: [
          ServicesScope(services: services, child: const AithraApp()),
          _SystemBars(dark: brightness == Brightness.dark),
        ],
      ),
    ),
  );
  await _settle(tester);
  return Harness(native, services);
}

/// Draws an Android-style status bar and gesture handle over the app.
class _SystemBars extends StatelessWidget {
  const _SystemBars({required this.dark});
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final fg = dark ? const Color(0xFFF2F2F2) : const Color(0xFF1C1C1C);
    const style = TextStyle(
      fontFamily: 'Roboto',
      fontSize: 14,
      fontWeight: FontWeight.w500,
    );
    return IgnorePointer(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: _statusBar,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Row(
                  children: [
                    Text('9:41', style: style.copyWith(color: fg)),
                    const Spacer(),
                    Icon(Icons.wifi_rounded, size: 16, color: fg),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.signal_cellular_alt_rounded,
                      size: 16,
                      color: fg,
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.battery_6_bar_rounded, size: 16, color: fg),
                    Text(
                      ' 82%',
                      style: style.copyWith(color: fg, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Center(
                child: Container(
                  width: 108,
                  height: 4,
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _push(WidgetTester tester, Widget screen) async {
  final nav = tester.state<NavigatorState>(find.byType(Navigator).last);
  unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => screen)));
  await _settle(tester, 16);
}

/// Decodes every image on screen for real (decoding needs real async).
Future<void> _decodeImages(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        final img = e.widget as Image;
        await precacheImage(img.image, e);
      }
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  final boundary =
      tester.renderObject(find.byKey(_rootKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _dpr);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(_outDir!).createSync(recursive: true);
    File('$_outDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _teardown(WidgetTester tester, Harness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  h.services.assistant.dispose();
  h.services.models.dispose();
}

Future<void> _loadFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final f in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(f['family']! as String);
    for (final a in (f['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(a['asset']! as String));
    }
    await loader.load();
  }
  final sdk =
      Platform.environment['FLUTTER_ROOT'] ??
      '${Platform.environment['HOME']}/development/flutter';
  final dir = '$sdk/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold']) {
    final bytes = File('$dir/Roboto-$w.ttf').readAsBytesSync();
    roboto.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await roboto.load();
}

// -- Scenarios --------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  group('screenshots', skip: _outDir == null ? 'set SCREENSHOT_DIR' : null, () {
    for (final b in [Brightness.dark, Brightness.light]) {
      final t = b == Brightness.dark ? 'dark' : 'light';

      testWidgets('onboarding $t', (tester) async {
        final h = await _build(
          tester,
          brightness: b,
          onboarded: false,
          withModels: false,
        );
        await _shot(tester, '01-onboarding-1-intro-$t');
        await tester.tap(find.text('Next'));
        await _settle(tester, 16);
        await _shot(tester, '02-onboarding-2-privacy-$t');
        await tester.tap(find.text('Next'));
        await _settle(tester, 16);
        await _shot(tester, '03-onboarding-3-download-$t');
        await _teardown(tester, h);
      });

      testWidgets('icon $t', (tester) async {
        final h = await _build(tester, brightness: b);
        await _push(tester, const _IconSheet());
        await _decodeImages(tester);
        await _shot(tester, '00-icon-$t');
        await _teardown(tester, h);
      });

      testWidgets('chat list $t', (tester) async {
        final h = await _build(tester, brightness: b);
        await _shot(tester, '04-chat-list-$t');
        await _teardown(tester, h);
      });

      testWidgets('chat streaming $t', (tester) async {
        final h = await _build(tester, brightness: b);
        final info = h.services.chats.items.firstWhere((c) => c.id == 'code');
        await _push(tester, ChatScreen(conversation: info));
        await tester.enterText(find.byType(TextField), _followUp);
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
        await _settle(tester);
        for (final chunk in _chunks(_streamed)) {
          h.native.tokens(chunk);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await _settle(tester);
        await _shot(tester, '05-chat-code-streaming-$t');
        await _teardown(tester, h);
      });

      testWidgets('chat image $t', (tester) async {
        final h = await _build(tester, brightness: b);
        final info = h.services.chats.items.firstWhere((c) => c.id == 'plant');
        await _push(tester, ChatScreen(conversation: info));
        await _decodeImages(tester);
        await _settle(tester);
        await _shot(tester, '06-chat-image-$t');
        await _teardown(tester, h);
      });

      testWidgets('voice $t', (tester) async {
        final h = await _build(tester, brightness: b);
        await _push(tester, const VoiceModeScreen());
        final n = h.native;
        n.emit({'type': 'speech', 'kind': 'begin', 't': 0, 'onDevice': true});
        n.emit({
          'type': 'speech',
          'kind': 'level',
          'rms': 6.5,
          't': 300,
          'onDevice': true,
        });
        n.emit({
          'type': 'speech',
          'kind': 'partial',
          'text': 'What should I pack for a two-day hike',
          't': 900,
          'onDevice': true,
        });
        await _settle(tester);
        await _shot(tester, '07-voice-listening-$t');
        n.emit({
          'type': 'speech',
          'kind': 'final',
          'text': 'What should I pack for a two-day hike in the Lake District?',
          't': 1800,
          'onDevice': true,
        });
        await _settle(tester);
        for (final chunk in _chunks(
          'Pack in layers: a waterproof jacket, a warm fleece and a spare base '
          'layer, because the weather on the fells changes fast. Bring a paper '
          'map and compass as well as your phone, since signal is patchy in the '
          'valleys. For two days you will want about two litres of water a ',
        )) {
          n.tokens(chunk);
          await tester.pump(const Duration(milliseconds: 16));
        }
        await _settle(tester);
        await _shot(tester, '08-voice-speaking-$t');
        await _teardown(tester, h);
      });

      testWidgets('memories $t', (tester) async {
        final h = await _build(tester, brightness: b);
        await _push(tester, const MemoriesScreen());
        await _shot(tester, '09-memories-$t');
        await _teardown(tester, h);
      });

      testWidgets('models $t', (tester) async {
        final h = await _build(tester, brightness: b);
        await _push(tester, const ModelsScreen());
        await _shot(tester, '10-models-$t');
        await tester.drag(find.byType(ListView).last, const Offset(0, -900));
        await _settle(tester);
        await _shot(tester, '10b-models-scrolled-$t');
        await _teardown(tester, h);
      });

      testWidgets('settings $t', (tester) async {
        final h = await _build(tester, brightness: b);
        await _push(tester, const SettingsScreen());
        await _shot(tester, '11-settings-$t');
        await _push(tester, const PerformanceScreen());
        await _shot(tester, '12-settings-performance-$t');
        await _teardown(tester, h);
      });
    }
  });
}

Iterable<String> _chunks(String s) sync* {
  for (var i = 0; i < s.length; i += 6) {
    yield s.substring(i, math.min(i + 6, s.length));
  }
}

/// The launcher icon as Android draws it (legacy PNG, adaptive icon in a
/// circle mask, themed monochrome) next to the in-app mark, for review.
class _IconSheet extends StatelessWidget {
  const _IconSheet();

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final png = File(
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
    ).readAsBytesSync();
    // The adaptive foreground draws the glyph 44 dp tall on a 108 dp canvas
    // whose middle 72 dp is visible; the painter fills 60% of its box.
    Widget adaptive(Color bg, Color fg) => ClipOval(
      child: SizedBox.square(
        dimension: 96,
        child: ColoredBox(
          color: bg,
          child: Center(
            child: SizedBox.square(
              dimension: 96 / 72 * 44 / 0.6,
              child: CustomPaint(painter: AithraGlyphPainter(color: fg)),
            ),
          ),
        ),
      ),
    );
    Widget labelled(String label, Widget child) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        const SizedBox(height: 8),
        Text(label, style: TextStyle(color: c.textSecondary, fontSize: 12)),
      ],
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Icon')),
      body: Center(
        child: Wrap(
          spacing: 32,
          runSpacing: 32,
          alignment: WrapAlignment.center,
          children: [
            labelled(
              'Legacy PNG',
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.memory(png, width: 96, height: 96),
              ),
            ),
            labelled('Adaptive', adaptive(aithraBrand, Colors.white)),
            labelled(
              'Themed',
              adaptive(const Color(0xFFDCE4F0), const Color(0xFF233046)),
            ),
            labelled('Mark 64', const AithraMark(size: 64)),
            labelled('Mark 30', const AithraMark(size: 30)),
          ],
        ),
      ),
    );
  }
}
