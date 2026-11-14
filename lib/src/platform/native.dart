import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// One message as the engines receive it.
class EngineTurn {
  const EngineTurn(
    this.role,
    this.text, [
    this.images = const [],
    this.context = '',
  ]);

  /// `system`, `user` or `model`.
  final String role;
  final String text;
  final List<Uint8List> images;

  /// Material retrieved for this turn only (recalled snippets), read in
  /// front of [text]. Per-turn material goes here rather than into the
  /// system turn, so the conversation's prefix stays the same from turn to
  /// turn and the engine can keep it (see `keepContext`).
  final String context;

  Map<String, Object?> toMap() => {
    'role': role,
    'text': text,
    'images': images,
    'context': context,
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

  /// A [background] generation is cancelled by any foreground one, from
  /// this engine or the other (the app and the Ask sheet share the model).
  Future<Map<String, Object?>> generate({
    required int requestId,
    required List<EngineTurn> turns,
    required int maxTokens,
    required double temperature,
    required bool ignoreEos,
    bool keepContext = false,
    bool background = false,
  }) => _map('engine.generate', {
    'requestId': requestId,
    'turns': [for (final t in turns) t.toMap()],
    'maxTokens': maxTokens,
    'temperature': temperature,
    'ignoreEos': ignoreEos,
    'keepContext': keepContext,
    'background': background,
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

  /// A [private] conversation is never embedded, so it is not recalled in
  /// other chats.
  Future<void> dbCreateConversation(
    String id,
    String title,
    int now, {
    bool private = false,
  }) => _channel.invokeMethod('db.createConversation', {
    'id': id,
    'title': title,
    'now': now,
    'private': private,
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

  /// Appends a message; returns its `id`, `seq`, `version` and
  /// `versionCount` (a regenerated reply follows its earlier versions).
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

  /// Deletes messages from [fromSeq] on, and their images and documents
  /// except [keepImages] and [keepDocs]. With [archive] (regenerate) the
  /// reply at [fromSeq] is kept as an earlier version of the one that
  /// replaces it.
  Future<void> dbTruncate(
    String convId,
    int fromSeq, {
    List<String> keepImages = const [],
    List<String> keepDocs = const [],
    bool archive = false,
  }) => _channel.invokeMethod('db.truncate', {
    'convId': convId,
    'fromSeq': fromSeq,
    'keepImages': keepImages,
    'keepDocs': keepDocs,
    'archive': archive,
  });

  /// Every version of the message at [seq], oldest first: `ord`,
  /// `content`, `stats`, `created` and `current` (the one on show).
  Future<List<Map<String, Object?>>> dbMessageVersions(
    String convId,
    int seq,
  ) => _rows('db.messageVersions', {'convId': convId, 'seq': seq});

  /// Shows version [ord] of the message at [seq] in place of the current
  /// one, which stays among its versions.
  Future<void> dbSelectVersion(String convId, int seq, int ord) =>
      _channel.invokeMethod('db.selectVersion', {
        'convId': convId,
        'seq': seq,
        'ord': ord,
      });

  Future<void> dbPutImage(String id, Uint8List jpeg) =>
      _channel.invokeMethod('db.putImage', {'id': id, 'jpeg': jpeg});

  Future<Uint8List?> dbImage(String id, {required bool thumb}) =>
      _channel.invokeMethod<Uint8List>('db.image', {'id': id, 'thumb': thumb});

  Future<List<Map<String, Object?>>> dbSearch(String query, int limit) =>
      _rows('db.search', {'query': query, 'limit': limit});

  /// Chats with a message where every word of [query] starts a word,
  /// ignoring case, newest first: conversation rows with the `seq` of the
  /// newest such message and a `snippet` of it around the match.
  Future<List<Map<String, Object?>>> dbSearchText(String query, int limit) =>
      _rows('db.searchText', {'query': query, 'limit': limit});

  /// Seqs of [convId]'s messages matching [query] as [dbSearchText] does,
  /// newest first.
  Future<List<int>> dbFindInChat(String convId, String query) async => [
    for (final s in await _call<List<Object?>>('db.findInChat', {
      'convId': convId,
      'query': query,
    }))
      s! as int,
  ];

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

  // -- Documents (DocumentStore.kt) ---------------------------------------

  static Map<String, Object?>? _optMap(Object? m) =>
      m == null ? null : Map<String, Object?>.from(m as Map);

  /// Lets the user pick a file and stores its text as an unattached
  /// document; null when the picker was dismissed. Progress arrives as
  /// `document` events.
  Future<Map<String, Object?>?> pickDocument() async =>
      _optMap(await _channel.invokeMethod<Object?>('doc.pick'));

  /// Reads the file at [uri] into an unattached document.
  Future<Map<String, Object?>> importDocumentUri(String uri) =>
      _map('doc.importUri', {'uri': uri});

  /// Reads a file a share copied in ([path], deleted once read) into an
  /// unattached document.
  Future<Map<String, Object?>> importSharedFile({
    required String path,
    required String name,
    required String? mime,
  }) => _map('doc.importShared', {'path': path, 'name': name, 'mime': mime});

  /// Stores [text] as an unattached document named [name].
  Future<Map<String, Object?>> importTextDocument(String name, String text) =>
      _map('doc.importText', {'name': name, 'text': text});

  Future<Map<String, Object?>?> document(String id) async =>
      _optMap(await _channel.invokeMethod<Object?>('doc.get', {'id': id}));

  Future<List<Map<String, Object?>>> documentsOf(String convId) =>
      _rows('doc.ofConversation', {'convId': convId});

  Future<void> attachDocuments(String convId, int msgId, List<String> ids) =>
      _channel.invokeMethod('doc.attach', {
        'convId': convId,
        'msgId': msgId,
        'ids': ids,
      });

  Future<void> deleteDocument(String id) =>
      _channel.invokeMethod('doc.delete', {'id': id});

  /// Pages that have text, in order: `page` and `text`.
  Future<List<Map<String, Object?>>> documentPages(String id) =>
      _rows('doc.pages', {'id': id});

  /// Scanned pages still to be read: `page` and the `image` id.
  Future<List<Map<String, Object?>>> unreadPages(String id) =>
      _rows('doc.unreadPages', {'id': id});

  Future<void> setPageText(String id, int page, String text) => _channel
      .invokeMethod('doc.setPageText', {'id': id, 'page': page, 'text': text});

  Future<void> setDocumentSummary(
    String id, {
    String? parts,
    String? summary,
  }) => _channel.invokeMethod('doc.setSummary', {
    'id': id,
    'parts': parts,
    'summary': summary,
  });

  Future<List<Map<String, Object?>>> pendingSummaries() =>
      _rows('doc.pendingSummaries', const {});

  /// Up to [limit] passages of [ids] in reading order.
  Future<List<Map<String, Object?>>> passagesInOrder(
    List<String> ids,
    int limit,
  ) => _rows('doc.passagesInOrder', {'ids': ids, 'limit': limit});

  Future<Map<String, Object?>?> passage(String docId, int ord) async => _optMap(
    await _channel.invokeMethod<Object?>('doc.passage', {
      'docId': docId,
      'ord': ord,
    }),
  );

  /// The [limit] passages of [ids] closest in meaning to [query].
  Future<List<Map<String, Object?>>> searchDocuments(
    String modelPath,
    List<String> ids,
    String query,
    int limit,
  ) => _rows('doc.search', {
    'modelPath': modelPath,
    'ids': ids,
    'query': query,
    'limit': limit,
  });

  Future<void> putCitations(int msgId, List<Map<String, Object?>> cites) =>
      _channel.invokeMethod('doc.putCitations', {
        'msgId': msgId,
        'cites': cites,
      });

  /// Every citation in [convId]: `msgId`, `docId`, `ord`, `page`, `name`.
  Future<List<Map<String, Object?>>> citations(String convId) =>
      _rows('doc.citations', {'convId': convId});

  // -- Inbox, notifications, languages --------------------------------------

  /// What another app shared, or a chat to open, once; null when nothing
  /// waits. An `inbox` event says something new arrived.
  Future<Map<String, Object?>?> takeInbox() async =>
      _optMap(await _channel.invokeMethod<Object?>('inbox.take'));

  /// Shows or updates the notification [tag]; with [done] it is an ongoing
  /// progress notification, without it one the user can swipe away.
  Future<void> notifyProgress({
    required String tag,
    required String title,
    required String text,
    int? done,
    int? total,
  }) => _channel.invokeMethod('notify.progress', {
    'tag': tag,
    'title': title,
    'text': text,
    'done': done,
    'total': total,
  });

  Future<void> cancelNotification(String tag) =>
      _channel.invokeMethod('notify.cancel', {'tag': tag});

  /// Language tags and English names, the user's own languages first.
  Future<List<({String tag, String name})>> languages() async => [
    for (final m in await _rows('locale.languages', const {}))
      (tag: m['tag']! as String, name: m['name']! as String),
  ];

  // -- Ask sheet (AskActivity) ----------------------------------------------

  /// The selected text and whether the calling app accepts a replacement.
  Future<({String text, bool readOnly})> askRequest() async {
    final m = await _map('ask.request');
    return (text: m['text']! as String, readOnly: m['readOnly']! as bool);
  }

  /// Returns [text] to the calling app in place of the selection.
  Future<void> askReplace(String text) =>
      _channel.invokeMethod('ask.replace', {'text': text});

  Future<void> askClose() => _channel.invokeMethod('ask.close');

  /// Opens the app, at chat [id] when given, and closes the sheet.
  Future<void> askOpenChat([String? id]) =>
      _channel.invokeMethod('ask.openChat', {'id': id});

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

  /// Writes [text] to a Markdown file for sharing; returns its path.
  Future<String> exportMarkdown(String name, String text) =>
      _call<String>('export.markdown', {'name': name, 'text': text});

  /// Draws a chat as an A4 PDF for sharing; returns its path. Each entry
  /// is `role`, `created` (epoch ms) and `blocks` of `kind` and `text`
  /// (see chat_export.dart).
  Future<String> exportPdf(
    String name,
    String title,
    List<Map<String, Object?>> entries,
  ) => _call<String>('export.pdf', {
    'name': name,
    'title': title,
    'entries': entries,
  });

  /// Offers the file at [path] to other apps through the share sheet.
  Future<void> shareFile(String path, String mime) =>
      _channel.invokeMethod('share.file', {'path': path, 'mime': mime});

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
