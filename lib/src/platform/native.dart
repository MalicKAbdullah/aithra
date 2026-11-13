import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// One message as the engines receive it.
class EngineTurn {
  const EngineTurn(this.role, this.text, [this.images = const []]);

  /// `system`, `user` or `model`.
  final String role;
  final String text;
  final List<Uint8List> images;

  Map<String, Object?> toMap() => {
    'role': role,
    'text': text,
    'images': images,
  };
}

/// Typed access to the Kotlin side (`MainActivity`). Everything that needs
/// the phone — models, downloads, speech, TTS, media — goes through here.
class NativeBridge {
  NativeBridge({MethodChannel? channel, Stream<Object?>? events})
    : _channel = channel ?? const MethodChannel('aithra/native'),
      _events =
          (events ??
                  const EventChannel('aithra/events').receiveBroadcastStream())
              .map((e) => Map<String, Object?>.from(e! as Map))
              .asBroadcastStream();

  final MethodChannel _channel;
  final Stream<Map<String, Object?>> _events;

  Stream<Map<String, Object?>> eventsOf(String type) =>
      _events.where((e) => e['type'] == type);

  Future<T> _call<T>(String method, [Map<String, Object?>? args]) async =>
      (await _channel.invokeMethod<T>(method, args)) as T;

  Future<Map<String, Object?>> _map(
    String method, [
    Map<String, Object?>? args,
  ]) async => Map<String, Object?>.from(
    (await _channel.invokeMethod<Map<Object?, Object?>>(method, args))!,
  );

  // -- Engine ---------------------------------------------------------------

  Future<Map<String, Object?>> load({
    required String runtime,
    required String path,
    required String backend,
    required int? threads,
    required bool vision,
    required int? maxTokens,
  }) => _map('engine.load', {
    'runtime': runtime,
    'path': path,
    'backend': backend,
    'threads': threads,
    'vision': vision,
    'maxTokens': maxTokens,
  });

  Future<Map<String, Object?>> generate({
    required int requestId,
    required List<EngineTurn> turns,
    required int maxTokens,
    required double temperature,
    required bool ignoreEos,
  }) => _map('engine.generate', {
    'requestId': requestId,
    'turns': [for (final t in turns) t.toMap()],
    'maxTokens': maxTokens,
    'temperature': temperature,
    'ignoreEos': ignoreEos,
  });

  /// Exact tokens each turn adds to a prompt and the prompt's remaining
  /// overhead, from the loaded model's tokenizer; both null when its
  /// runtime has none.
  Future<({List<int>? counts, int? overhead})> countTokens(
    List<EngineTurn> turns,
  ) async {
    final m = await _map('engine.countTokens', {
      'turns': [
        for (final t in turns) {'role': t.role, 'text': t.text},
      ],
    });
    final counts = m['counts'] as List?;
    return (
      counts: counts == null ? null : [for (final c in counts) c as int],
      overhead: m['overhead'] as int?,
    );
  }

  /// Cancels generation [requestId], queued or running.
  Future<void> cancel(int requestId) =>
      _channel.invokeMethod('engine.cancel', {'requestId': requestId});

  Future<void> unload() => _channel.invokeMethod('engine.unload');

  // -- Encrypted chat store (Android SQLite, see ChatDb.kt) ----------------

  Future<void> dbOpen(Uint8List key) =>
      _channel.invokeMethod('db.open', {'key': key});

  Future<List<Map<String, Object?>>> _rows(
    String method,
    Map<String, Object?> args,
  ) async => [
    for (final e in await _call<List<Object?>>(method, args))
      Map<String, Object?>.from(e! as Map),
  ];

  Future<List<Map<String, Object?>>> dbConversations(int offset, int limit) =>
      _rows('db.conversations', {'offset': offset, 'limit': limit});

  Future<Map<String, Object?>?> dbConversation(String id) async {
    final m = await _channel.invokeMethod<Map<Object?, Object?>>(
      'db.conversation',
      {'id': id},
    );
    return m == null ? null : Map<String, Object?>.from(m);
  }

  Future<void> dbCreateConversation(String id, String title, int now) =>
      _channel.invokeMethod('db.createConversation', {
        'id': id,
        'title': title,
        'now': now,
      });

  Future<void> dbUpdateConversation(String id, Map<String, Object?> fields) =>
      _channel.invokeMethod('db.updateConversation', {
        'id': id,
        'fields': fields,
      });

  Future<void> dbDeleteConversation(String id) =>
      _channel.invokeMethod('db.deleteConversation', {'id': id});

  Future<List<Map<String, Object?>>> dbMessages(
    String convId,
    int beforeSeq,
    int limit,
  ) => _rows('db.messages', {
    'convId': convId,
    'beforeSeq': beforeSeq,
    'limit': limit,
  });

  Future<List<Map<String, Object?>>> dbMessageRange(
    String convId,
    int fromSeq,
    int toSeq,
  ) => _rows('db.messageRange', {
    'convId': convId,
    'fromSeq': fromSeq,
    'toSeq': toSeq,
  });

  Future<Map<String, Object?>> dbAddMessage({
    required String convId,
    required String role,
    required String content,
    required List<String> images,
    required String? stats,
    required int now,
  }) => _map('db.addMessage', {
    'convId': convId,
    'role': role,
    'content': content,
    'images': images,
    'stats': stats,
    'now': now,
  });

  Future<void> dbUpdateMessage(int id, String content, String? stats) =>
      _channel.invokeMethod('db.updateMessage', {
        'id': id,
        'content': content,
        'stats': stats,
      });

  /// Caches token counts (message id → count) made by [model]'s tokenizer.
  Future<void> dbSetTokens(Map<int, int> counts, String model) =>
      _channel.invokeMethod('db.setTokens', {
        'counts': {for (final e in counts.entries) '${e.key}': e.value},
        'model': model,
      });

  /// Deletes messages from [fromSeq] on, and their images except
  /// [keepImages].
  Future<void> dbTruncate(
    String convId,
    int fromSeq, {
    List<String> keepImages = const [],
  }) => _channel.invokeMethod('db.truncate', {
    'convId': convId,
    'fromSeq': fromSeq,
    'keepImages': keepImages,
  });

  Future<void> dbPutImage(String id, Uint8List jpeg) =>
      _channel.invokeMethod('db.putImage', {'id': id, 'jpeg': jpeg});

  Future<Uint8List?> dbImage(String id, {required bool thumb}) =>
      _channel.invokeMethod<Uint8List>('db.image', {'id': id, 'thumb': thumb});

  Future<List<Map<String, Object?>>> dbSearch(String query, int limit) =>
      _rows('db.search', {'query': query, 'limit': limit});

  /// Chats with a message containing [query], ignoring case, newest first:
  /// conversation rows with a `snippet` of the message around the match.
  Future<List<Map<String, Object?>>> dbSearchText(String query, int limit) =>
      _rows('db.searchText', {'query': query, 'limit': limit});

  /// Past messages from other chats closest in meaning to [query], using
  /// the embedding model at [modelPath].
  Future<List<Map<String, Object?>>> dbRecall(
    String modelPath,
    String query,
    String? excludeConv,
    int limit,
  ) => _rows('db.recall', {
    'modelPath': modelPath,
    'query': query,
    'excludeConv': excludeConv,
    'limit': limit,
  });

  /// Messages closest in meaning to [query], one per conversation.
  Future<List<Map<String, Object?>>> dbSearchMessages(
    String modelPath,
    String query,
    int limit,
  ) => _rows('db.searchMessages', {
    'modelPath': modelPath,
    'query': query,
    'limit': limit,
  });

  /// Unit vectors for [texts] from the embedding model at [modelPath],
  /// embedded as search queries or as documents to be found.
  Future<List<Float32List>> embed(
    String modelPath,
    List<String> texts, {
    required bool query,
  }) async => [
    for (final v in (await _channel.invokeMethod<List<Object?>>('embed.texts', {
      'modelPath': modelPath,
      'texts': texts,
      'query': query,
    }))!)
      v! as Float32List,
  ];

  Future<({int indexed, int total})> dbVectorStatus() async {
    final m = await _map('db.vectorStatus');
    return (indexed: m['indexed']! as int, total: m['total']! as int);
  }

  /// Embeds up to [limit] unindexed messages; returns how many (0 when done).
  Future<int> dbIndexVectors(String modelPath, int limit) async =>
      (await _channel.invokeMethod<int>('db.indexVectors', {
        'modelPath': modelPath,
        'limit': limit,
      }))!;

  Future<Map<String, Object?>> dbSelfTest(int messages) =>
      _map('db.selfTest', {'messages': messages});

  // -- Device & files -------------------------------------------------------

  Future<Map<String, Object?>> deviceInfo() => _map('device.info');

  /// Models folder and free space on shared storage.
  Future<Map<String, Object?>> storageInfo() => _map('storage.info');

  /// Internal app storage for the encrypted settings and memories.
  Future<String> dataDir() => _call<String>('storage.dataDir');

  /// Whether encrypted chats, settings or memories exist on the phone.
  Future<bool> hasData() => _call<bool>('storage.hasData');

  /// Deletes every encrypted chat, setting and memory; models stay.
  Future<void> eraseData() => _channel.invokeMethod('storage.erase');

  /// Whether the CPU has the instructions llama.cpp is built for; without
  /// them GGUF models and cross-chat memory cannot run.
  Future<bool> runsLlama() => _call<bool>('device.runsLlama');

  // -- Crash report ---------------------------------------------------------

  /// What went wrong since the report was last cleared, or null.
  Future<String?> crashRead() => _channel.invokeMethod<String>('crash.read');

  Future<void> crashRecord(String title, String detail) =>
      _channel.invokeMethod('crash.record', {'title': title, 'detail': detail});

  Future<void> crashClear() => _channel.invokeMethod('crash.clear');

  Future<List<Map<String, Object?>>> listModelFiles() async => [
    for (final e in await _call<List<Object?>>('file.list'))
      Map<String, Object?>.from(e! as Map),
  ];

  Future<void> deleteFile(String path) =>
      _channel.invokeMethod('file.delete', {'path': path});

  /// Starts (or returns the running) download of [fileName]; it resumes
  /// after connection drops and is checked against [sha256].
  Future<int> startDownload({
    required String url,
    required String fileName,
    required String title,
    required int size,
    required String sha256,
  }) => _call<int>('download.start', {
    'url': url,
    'fileName': fileName,
    'title': title,
    'size': size,
    'sha256': sha256,
  });

  Future<List<Map<String, Object?>>> queryDownloads() async => [
    for (final e in await _call<List<Object?>>('download.query'))
      Map<String, Object?>.from(e! as Map),
  ];

  Future<void> removeDownload(int id) =>
      _channel.invokeMethod('download.remove', {'id': id});

  /// Lets the user pick a model file and copies it into the models folder.
  /// Returns the new path, or null when the picker was dismissed.
  Future<String?> importModel() =>
      _channel.invokeMethod<String>('import.model');

  // -- Media ----------------------------------------------------------------

  /// System photo picker; returns a downsized JPEG or null when dismissed.
  Future<Uint8List?> pickImage() =>
      _channel.invokeMethod<Uint8List>('media.pickImage');

  /// System camera app; returns a downsized JPEG or null when dismissed.
  Future<Uint8List?> capturePhoto() =>
      _channel.invokeMethod<Uint8List>('media.capture');

  Future<void> shareText(String text) =>
      _channel.invokeMethod('share.text', {'text': text});

  // -- Speech ---------------------------------------------------------------

  /// `granted`, `denied`, or `blocked` when only Settings can grant it.
  Future<String> requestMicrophone() => _call<String>('permission.microphone');

  /// Aithra's page in system Settings, where permissions are granted.
  Future<void> openAppSettings() =>
      _channel.invokeMethod('permission.openSettings');

  Future<Map<String, Object?>> speechStatus() => _map('speech.status');

  Future<void> startListening({required bool continuous}) =>
      _channel.invokeMethod('speech.start', {'continuous': continuous});

  Future<void> stopListening() => _channel.invokeMethod('speech.stop');

  Future<void> cancelListening() => _channel.invokeMethod('speech.cancel');

  Future<bool> downloadSpeechModel() => _call<bool>('speech.downloadModel');

  Future<void> openVoiceSettings() =>
      _channel.invokeMethod('speech.openSettings');

  Future<void> speak(String text, String id) =>
      _channel.invokeMethod('tts.speak', {'text': text, 'id': id});

  Future<void> stopSpeaking() => _channel.invokeMethod('tts.stop');
}
