import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../assistant.dart';
import '../docs/documents.dart';
import '../engine/engine_service.dart';
import '../memory/memory_keeper.dart';
import '../memory/profile.dart';
import '../memory/recall_index.dart';
import '../models/catalog.dart';
import '../platform/native.dart';
import '../share/shared_item.dart';
import 'chat_models.dart';
import 'chat_titler.dart';
import 'chat_store.dart';
import 'context_builder.dart';
import 'reply_queue.dart';

/// Reply text that grows while tokens stream in. Chunks are coalesced and
/// published at most once per frame, so only the streaming bubble rebuilds
/// and it rebuilds at the display rate, not the token rate.
class StreamingText extends ValueNotifier<String> {
  StreamingText() : super('');

  final StringBuffer _buffer = StringBuffer();
  bool _scheduled = false;

  void add(String chunk) {
    _buffer.write(chunk);
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _scheduled = false;
      value = _buffer.toString();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  String get full => _buffer.toString();

  /// Empties the text for a new reply.
  void reset() {
    _buffer.clear();
    value = '';
  }
}

enum ReplyPhase {
  idle,

  /// Waiting for another chat's reply to finish with the engine.
  queued,
  preparing,
  streaming,
}

/// Something that did not work for a reply; the reply itself is fine.
class ReplyNotice {
  const ReplyNotice(this.title, this.details, {this.recall = false});

  const ReplyNotice.recall(String message)
    : title = 'Memory across chats unavailable',
      details =
          'Aithra answered without looking at your other chats because '
          'recall failed: $message',
      recall = true;

  final String title;
  final String details;

  /// A recall failure, which the user can retry.
  final bool recall;
}

/// An image attached in the composer, before it is stored.
class PendingImage {
  PendingImage(this.jpeg);
  final Uint8List jpeg;
}

/// One chat: its messages (paged newest first), the reply being generated,
/// and the actions on it (send, stop, regenerate, edit). A session outlives
/// the screen that shows it while its reply runs (see ChatSessions), so all
/// reply state lives here.
class ChatSession extends ChangeNotifier {
  ChatSession({
    required NativeBridge native,
    required Assistant assistant,
    required ChatStore store,
    required MemoryKeeper keeper,
    required RecallIndex recall,
    required ReplyQueue queue,
    ConversationInfo? conversation,
  }) : _native = native,
       _assistant = assistant,
       _store = store,
       _keeper = keeper,
       _recallIndex = recall,
       _queue = queue,
       _conversation = conversation;

  static const int pageSize = 30;
  static const int replyTokens = 1024;
  static const int summaryTokens = 256;

  final NativeBridge _native;
  final Assistant _assistant;
  final ChatStore _store;
  final MemoryKeeper _keeper;
  final RecallIndex _recallIndex;
  final ReplyQueue _queue;
  bool _disposed = false;

  ConversationInfo? _conversation;
  final List<ChatMessage> _messages = [];
  bool _hasMore = true;
  bool _loading = false;
  int _localSeq = -1;

  ReplyPhase phase = ReplyPhase.idle;
  final StreamingText streaming = StreamingText();
  Completer<void>? _replying;

  /// Completes once the reply in progress, if any, has ended and been
  /// saved.
  Future<void> get settled => _replying?.future ?? Future.value();
  Generation? _generation;
  bool _stopRequested = false;
  String? error;

  /// Full text of the most recent reply, including the tail that may not
  /// have been published to [streaming] before the reply ended.
  String lastReply = '';

  /// Problems that affected a reply, keyed by the reply's seq, shown under
  /// it for this session.
  final Map<int, ReplyNotice> notices = {};

  /// Replies (by seq) after which the model updated the user's profile;
  /// each shows a quiet hint that can undo the change.
  final Map<int, MemoryUpdate> memoryUpdates = {};

  /// Leaves memory out of this chat: the profile and other chats are not
  /// used in its prompts, and nothing said in it is learned.
  bool skipMemory = false;

  bool get _remembering => _assistant.settings.memoryEnabled && !skipMemory;

  /// Documents sent with each user message, by message id.
  final Map<int, List<DocInfo>> attachments = {};

  /// The passages each reply was given, by message id: its Sources row.
  final Map<int, List<Source>> sources = {};

  /// What the reply is doing before it streams, when that takes a while
  /// (reading scanned pages); null otherwise.
  final ValueNotifier<String?> activity = ValueNotifier(null);

  /// Something shared from another app, for the composer to take.
  final ValueNotifier<SharedItem?> incoming = ValueNotifier(null);

  ConversationInfo? get conversation => _conversation;

  /// Newest first (the list view is reversed).
  List<ChatMessage> get messages => _messages;
  bool get hasMore => _hasMore && _conversation != null;
  bool get busy => phase != ReplyPhase.idle;

  Future<void> loadMore() async {
    final conv = _conversation;
    if (conv == null || _loading || !_hasMore) return;
    _loading = true;
    try {
      final before = _messages.isEmpty ? 1 << 30 : _messages.last.seq;
      final rows = await _native.dbMessages(conv.id, before, pageSize);
      if (_messages.isEmpty) await _loadDocuments(conv.id);
      _messages.addAll(rows.map(ChatMessage.fromMap));
      _hasMore = rows.length == pageSize;
      notifyListeners();
    } finally {
      _loading = false;
    }
  }

  /// The chat's documents and citations, which are few: all at once.
  Future<void> _loadDocuments(String convId) async {
    final docs = await _native.documentsOf(convId);
    final cites = await _native.citations(convId);
    attachments.clear();
    sources.clear();
    for (final d in docs.map(DocInfo.fromMap)) {
      (attachments[d.msgId!] ??= []).add(d);
    }
    for (final c in cites) {
      (sources[c['msgId']! as int] ??= []).add(Source.fromMap(c));
    }
  }

  /// Reads the chat again from the store: a summary finished in the
  /// background added a message.
  Future<void> reload() async {
    if (busy || _conversation == null) return;
    _messages.clear();
    _hasMore = true;
    await loadMore();
  }

  Future<void> saveDraft(String text) async {
    final conv = _conversation;
    if (conv == null) return;
    await _native.dbUpdateConversation(conv.id, {'draft': text});
  }

  Future<void> saveScroll(double offset) async {
    final conv = _conversation;
    if (conv == null) return;
    await _native.dbUpdateConversation(conv.id, {'scroll': offset});
  }

  /// Sends a user message with new [images], [keepImageIds] (images already
  /// stored: an edited message keeps its photos) and [docs]. Without
  /// [reply] the message is only saved (a document summary answers it).
  Future<void> send(
    String text,
    List<PendingImage> images, {
    List<String> keepImageIds = const [],
    List<DocInfo> docs = const [],
    bool reply = true,
  }) async {
    if (busy ||
        (text.trim().isEmpty &&
            images.isEmpty &&
            keepImageIds.isEmpty &&
            docs.isEmpty)) {
      return;
    }
    _assistant.engine.preemptBackground();
    unawaited(HapticFeedback.lightImpact());
    error = null;
    final now = DateTime.now();
    // Optimistic: the message shows before anything is written.
    final optimistic = ChatMessage(
      id: -1,
      seq: _localSeq--,
      role: Role.user,
      content: text.trim(),
      imageIds: keepImageIds,
      created: now,
    );
    _messages.insert(0, optimistic);
    phase = _queue.busy ? ReplyPhase.queued : ReplyPhase.preparing;
    streaming.value = '';
    notifyListeners();

    try {
      final convId = await _ensureConversation(
        text.trim().isEmpty && docs.isNotEmpty ? docs.first.name : text,
      );
      final imageIds = [...keepImageIds];
      for (final img in images) {
        final id = '${now.microsecondsSinceEpoch}-${imageIds.length}';
        await _native.dbPutImage(id, img.jpeg);
        imageIds.add(id);
      }
      final saved = await _native.dbAddMessage(
        convId: convId,
        role: 'user',
        content: text.trim(),
        images: imageIds,
        stats: null,
        now: now.millisecondsSinceEpoch,
      );
      _messages[_messages.indexOf(optimistic)] = ChatMessage(
        id: saved['id']! as int,
        seq: saved['seq']! as int,
        role: Role.user,
        content: text.trim(),
        imageIds: imageIds,
        created: now,
      );
      if (docs.isNotEmpty) {
        final msgId = saved['id']! as int;
        await _native.attachDocuments(convId, msgId, [
          for (final d in docs) d.id,
        ]);
        attachments[msgId] = [for (final d in docs) d.sentIn(convId, msgId)];
      }
      if (!reply) phase = ReplyPhase.idle;
      notifyListeners();
      unawaited(_store.upsert(convId));
    } catch (e) {
      // Nothing was saved, so the message leaves the list with the error.
      _messages.remove(optimistic);
      error = e is PlatformException ? (e.message ?? e.code) : '$e';
      phase = ReplyPhase.idle;
      notifyListeners();
      return;
    }
    if (reply) {
      await _reply(
        recallQuery: text.trim().isEmpty && docs.isNotEmpty
            ? docs.first.name
            : text,
      );
    }
  }

  Future<String> _ensureConversation(String firstText) async {
    final existing = _conversation;
    if (existing != null) return existing.id;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _native.dbCreateConversation(id, titleFrom(firstText), now);
    _conversation = ConversationInfo.fromMap(
      (await _native.dbConversation(id))!,
    );
    _hasMore = false;
    return id;
  }

  Future<void> _reply({required String recallQuery}) async {
    final done = _replying = Completer<void>();
    try {
      await _replyIn(_conversation!, recallQuery);
    } finally {
      _replying = null;
      done.complete();
    }
  }

  Future<void> _replyIn(ConversationInfo conv, String recallQuery) async {
    phase = _queue.busy ? ReplyPhase.queued : ReplyPhase.preparing;
    lastReply = '';
    _stopRequested = false;
    notifyListeners();
    if (!await _queue.acquire(this)) {
      // Stopped while it waited for another chat's reply.
      phase = ReplyPhase.idle;
      notifyListeners();
      return;
    }
    if (phase == ReplyPhase.queued) {
      phase = ReplyPhase.preparing;
      notifyListeners();
    }
    try {
      final prepared = await _assistant.prepare();
      if (prepared == null) {
        throw StateError('No model is ready. Download one in Models.');
      }
      final (spec, _) = prepared;
      final contextSize = _assistant.engine.contextSize!;
      final fresh = ConversationInfo.fromMap(
        (await _native.dbConversation(conv.id))!,
      );
      _conversation = fresh;
      final history = [
        for (final r in await _native.dbMessageRange(
          conv.id,
          fresh.summarizedUpto,
          1 << 30,
        ))
          ChatMessage.fromMap(r),
      ];
      final settings = _assistant.settings;
      final remembering = _remembering;
      final recall = remembering
          ? await _recallIndex.recall(recallQuery, conv.id)
          : const RecallOff();
      final recalled = switch (recall) {
        Recalled(:final messages) => messages,
        RecallOff() || RecallFailed() => const <RecalledMessage>[],
      };
      final context = SystemContext(
        now: DateTime.now(),
        aboutUser: settings.aboutUser,
        replyStyle: settings.replyStyle,
        memories: remembering
            ? await _keeper.forPrompt(recallQuery, rank: recall is Recalled)
            : const [],
        recalled: recalled,
        summary: fresh.summary,
      );
      final full = buildSystemPrompt(context);
      final counted = await _countTokens(spec, full, history);
      final system = await fitSystemPrompt(
        context,
        budget: systemBudget(contextSize),
        firstCost: counted.system,
        cost: counted.cost,
      );
      final systemTokens = identical(system, full)
          ? counted.system
          : await counted.cost(system);
      final messages = [
        for (final m in history)
          PromptMessage(
            seq: m.seq,
            isUser: m.role == Role.user,
            text: m.content,
            imageCount: spec.vision ? _imagesSent(history, m) : 0,
            tokens: counted.messages[m.id]!,
          ),
      ];
      final latest = messages.last;
      final room = contextSize - replyTokens - systemTokens - counted.overhead;
      final docs = await _documents(conv.id, spec);
      if (_stopRequested) return;
      final reading = await readDocuments(
        native: _native,
        docs: docs,
        question: history.last.content,
        budget: min(documentBudget(contextSize), room - latest.tokens),
        embedderPath: _assistant.models.pathOf(embeddingModel),
        costs: counted.costs,
      );
      final withDocs = reading == null
          ? latest
          : latest.withText(
              withDocuments(reading, latest.text),
              await counted.cost(withDocuments(reading, latest.text)),
            );
      final newest = await fitMessage(withDocs, room: room, cost: counted.cost);
      messages.last = newest;
      final plan = planPrompt(
        system: system,
        history: messages,
        contextTokens: contextSize,
        replyTokens: replyTokens,
        systemTokens: systemTokens,
        overheadTokens: counted.overhead,
      );
      final turns = <EngineTurn>[EngineTurn('system', plan.system)];
      for (final p in plan.messages) {
        final m = history.firstWhere((h) => h.seq == p.seq);
        final images = <Uint8List>[];
        if (p.imageCount > 0) {
          for (final id in m.imageIds) {
            final bytes = await _native.dbImage(id, thumb: false);
            if (bytes != null) images.add(bytes);
          }
        }
        turns.add(EngineTurn(p.isUser ? 'user' : 'model', p.text, images));
      }

      // Stop pressed while the model loaded or the prompt was assembled.
      if (_stopRequested) return;
      final generation = _assistant.engine.generate(
        turns,
        maxTokens: replyTokens,
      );
      _generation = generation;
      final sub = generation.text.listen((chunk) {
        if (phase != ReplyPhase.streaming) {
          phase = ReplyPhase.streaming;
          notifyListeners();
        }
        streaming.add(chunk);
      });
      final metrics = await generation.done;
      await sub.cancel();
      if (counted.estimated && turns.every((t) => t.images.isEmpty)) {
        if (metrics.promptTokens case final tokens?) {
          final bytes = turns.fold(0, (n, t) => n + utf8.encode(t.text).length);
          unawaited(_assistant.observeTokensPerByte(spec, tokens / bytes));
        }
      }
      final interrupted = generation.cancelled && !_stopRequested;
      final text = streaming.full.trim();
      if (text.isEmpty) {
        if (interrupted) {
          error =
              'Android needed memory back before Aithra could answer. '
              'Try again.';
        }
        return;
      }
      final saved = await _native.dbAddMessage(
        convId: conv.id,
        role: 'model',
        content: text,
        images: const [],
        stats: jsonEncode(metrics.toJson()),
        now: DateTime.now().millisecondsSinceEpoch,
      );
      _messages.insert(
        0,
        ChatMessage(
          id: saved['id']! as int,
          seq: saved['seq']! as int,
          role: Role.model,
          content: text,
          imageIds: const [],
          created: DateTime.now(),
          stats: metrics,
        ),
      );
      unawaited(HapticFeedback.selectionClick());
      unawaited(_store.upsert(conv.id));
      final replySeq = saved['seq']! as int;
      if (recall case RecallFailed(:final message)) {
        notices[replySeq] = ReplyNotice.recall(message);
      }
      if (interrupted) {
        notices[replySeq] = const ReplyNotice(
          'Reply cut short',
          'Android needed memory back while Aithra was answering, so this '
              'reply stopped early. Regenerate it for a full answer.',
        );
      }
      if (!identical(newest, withDocs)) {
        notices[replySeq] = ReplyNotice(
          'Your message was shortened',
          "It was too long for ${spec.name}'s memory, so Aithra read its "
              'beginning and end and left out part of the middle.',
        );
      }
      if (reading != null && reading.cited.isNotEmpty) {
        final replyId = saved['id']! as int;
        await _native.putCitations(replyId, [
          for (final p in reading.cited) {'docId': p.docId, 'ord': p.ord},
        ]);
        final names = {for (final d in docs) d.id: d.name};
        sources[replyId] = [
          for (final p in reading.cited)
            Source(
              docId: p.docId,
              ord: p.ord,
              page: p.page,
              name: names[p.docId]!,
            ),
        ];
      }
      if (_documentNotice(docs, reading, spec) case final notice?) {
        notices[replySeq] = notice;
      }
      final used = metrics.contextTokens ?? plan.promptTokens;
      if (shouldSummarize(
        usedTokens: used,
        contextTokens: contextSize,
        replyTokens: replyTokens,
      )) {
        _reportFailures(
          replySeq,
          _summarize(cost: counted.cost, contextTokens: contextSize),
        );
      }
      final asked = history.lastWhere((m) => m.role == Role.user);
      _reportFailures(
        replySeq,
        _afterReply(conv.id, replySeq, history, asked.content, text),
      );
    } catch (e) {
      error = e is PlatformException ? (e.message ?? e.code) : '$e';
    } finally {
      _queue.release(this);
      _generation = null;
      lastReply = streaming.full;
      phase = ReplyPhase.idle;
      streaming.value = '';
      streaming._buffer.clear();
      notifyListeners();
    }
  }

  /// Shows a failure of [work], which runs after the reply, under it.
  void _reportFailures(int replySeq, Future<void> work) {
    unawaited(
      work.catchError((Object e) {
        if (e is! PlatformException) throw e;
        if (_disposed) return;
        notices[replySeq] = ReplyNotice(
          'Background task failed',
          'After this reply Aithra could not finish its housekeeping '
              '(naming the chat, updating memory or summarizing): '
              '${e.message ?? e.code}',
        );
        notifyListeners();
      }),
    );
  }

  /// Housekeeping once the reply is in and the engine is free: naming a new
  /// chat, letting the model update the user's profile and embedding the new
  /// messages for recall. Each step yields to the user's next message (see
  /// [BackgroundRun]); a new message ends the whole run.
  Future<void> _afterReply(
    String convId,
    int replySeq,
    List<ChatMessage> history,
    String asked,
    String reply,
  ) async {
    final run = _assistant.engine.backgroundRun();
    final firstUser = history.where((m) => m.role == Role.user).toList();
    if (firstUser.length == 1 && history.first.seq == 0) {
      final provisional = titleFrom(firstUser.single.content);
      final raw = await run.generate(
        ChatTitler.prompt(asked, reply),
        maxTokens: ChatTitler.maxTokens,
      );
      final title = raw == null ? null : ChatTitler.parse(raw);
      final current = await _native.dbConversation(convId);
      // Only replace the provisional title, never one the user chose.
      if (title != null && current?['title'] == provisional) {
        await _store.rename(convId, title);
        if (!_disposed && _conversation?.id == convId) {
          _conversation = _conversation!.copyWith(title: title);
          notifyListeners();
        }
      }
    }
    if (_remembering) {
      final update = await _keeper.learn(run, asked: asked);
      if (update != null && !_disposed) {
        memoryUpdates[replySeq] = update;
        notifyListeners();
      }
    }
    await _keeper.catchUp(run);
    if (!run.preempted) _recallIndex.indexInBackground();
  }

  /// Token counts for [history] and [system] under [spec], and a [cost]
  /// for re-measuring a shortened message. Exact with a tokenizer: messages
  /// keep their count in the database, so only those new since the last
  /// turn (or counted by another model) are tokenized, in one call with the
  /// system prompt. Without one, every count is an [estimateTokens] and the
  /// prompt's template markup is folded into the measured ratio.
  Future<
    ({
      Map<int, int> messages,
      int system,
      int overhead,
      bool estimated,
      Future<int> Function(String text) cost,
      Future<List<int>> Function(List<String> texts) costs,
    })
  >
  _countTokens(ModelSpec spec, String system, List<ChatMessage> history) async {
    final cached = {
      for (final m in history)
        if (m.tokens != null && m.tokensModel == spec.id) m.id: m.tokens!,
    };
    final missing = [
      for (final m in history)
        if (!cached.containsKey(m.id)) m,
    ];
    final engine = _assistant.engine;
    final r = await engine.countTokens([
      EngineTurn('system', system),
      for (final m in missing)
        EngineTurn(m.role == Role.user ? 'user' : 'model', m.content),
    ]);
    final counts = r.counts;
    if (counts == null) {
      final ratio = _assistant.tokensPerByte(spec);
      return (
        messages: {
          for (final m in history) m.id: estimateTokens(m.content, ratio),
        },
        system: estimateTokens(system, ratio),
        overhead: 0,
        estimated: true,
        cost: (String text) async => estimateTokens(text, ratio),
        costs: (List<String> texts) async => [
          for (final t in texts) estimateTokens(t, ratio),
        ],
      );
    }
    final fresh = {
      for (var i = 0; i < missing.length; i++) missing[i].id: counts[i + 1],
    };
    if (fresh.isNotEmpty) await _native.dbSetTokens(fresh, spec.id);
    return (
      messages: {...cached, ...fresh},
      system: counts.first,
      overhead: r.overhead!,
      estimated: false,
      cost: (String text) async =>
          (await engine.countTokens([EngineTurn('user', text)])).counts!.single,
      costs: (List<String> texts) async => (await engine.countTokens([
        for (final t in texts) EngineTurn('user', t),
      ])).counts!,
    );
  }

  /// The chat's documents, with any scanned pages read first by the vision
  /// model so the question can be answered from them.
  Future<List<DocInfo>> _documents(String convId, ModelSpec spec) async {
    final docs = [
      for (final r in await _native.documentsOf(convId)) DocInfo.fromMap(r),
    ];
    if (!spec.vision || docs.every((d) => d.unreadPages == 0)) {
      return docs;
    }
    try {
      for (final d in docs.where((d) => d.unreadPages > 0)) {
        final pages = await _native.unreadPages(d.id);
        for (final (i, p) in pages.indexed) {
          final page = p['page']! as int;
          activity.value =
              'Reading ${d.name}, page $page (${i + 1} of ${pages.length})';
          final image = await _native.dbImage(
            p['image']! as String,
            thumb: false,
          );
          final g = _assistant.engine.generate(
            [
              EngineTurn('user', readPagePrompt, [image!]),
            ],
            maxTokens: replyTokens,
            temperature: 0,
          );
          _generation = g;
          final text = await g.text.join();
          await g.done;
          if (g.cancelled) return docs;
          await _native.setPageText(d.id, page, text);
        }
      }
    } finally {
      _generation = null;
      activity.value = null;
    }
    return [
      for (final r in await _native.documentsOf(convId)) DocInfo.fromMap(r),
    ];
  }

  /// What the user should know about how the documents were read.
  ReplyNotice? _documentNotice(
    List<DocInfo> docs,
    DocumentContext? reading,
    ModelSpec spec,
  ) {
    final unread = docs.fold(0, (n, d) => n + d.unreadPages);
    final unreadable = docs.fold(0, (n, d) => n + d.unreadablePages);
    if (unread > 0) {
      return ReplyNotice(
        'Scanned pages not read',
        "$unread scanned ${unread == 1 ? 'page has' : 'pages have'} no text "
            "layer, and ${spec.name} can't read images. Choose a model that "
            'understands images in Models to include them.',
      );
    }
    if (reading != null && !reading.whole && !reading.searched) {
      return const ReplyNotice(
        'Read the beginning only',
        'The document is longer than fits in one answer, so Aithra read its '
            'opening passages. Download "Memory across chats" in Models and '
            'Aithra finds the passages your question is about.',
      );
    }
    if (unreadable > 0) {
      return ReplyNotice(
        'Some pages not read',
        '$unreadable scanned ${unreadable == 1 ? 'page' : 'pages'} had no '
            'text Aithra could read, or came after the scanned pages Aithra '
            'reads in one document.',
      );
    }
    return null;
  }

  /// Images are sent for the two most recent user messages that have any;
  /// older ones stay in the chat but not in the prompt.
  int _imagesSent(List<ChatMessage> history, ChatMessage m) {
    if (m.imageIds.isEmpty) return 0;
    final withImages = history.where((h) => h.imageIds.isNotEmpty).toList();
    final recent = withImages.skip(
      withImages.length - 2 < 0 ? 0 : withImages.length - 2,
    );
    return recent.contains(m) ? m.imageIds.length : 0;
  }

  /// Folds older turns into the conversation summary so the chat keeps its
  /// meaning while staying inside the model's context.
  Future<void> _summarize({
    required Future<int> Function(String text) cost,
    required int contextTokens,
  }) async {
    final conv = _conversation;
    if (conv == null) return;
    final fresh = ConversationInfo.fromMap(
      (await _native.dbConversation(conv.id))!,
    );
    final history = [
      for (final r in await _native.dbMessageRange(
        conv.id,
        fresh.summarizedUpto,
        1 << 30,
      ))
        ChatMessage.fromMap(r),
    ];
    final fold = messagesToSummarize(history);
    if (fold.isEmpty) return;
    final text = summarizePrompt(fresh.summary, [
      for (final m in fold) (isUser: m.role == Role.user, text: m.content),
    ]);
    // The folded turns include any message that was shortened to fit its
    // own reply, so the summary request is fitted the same way.
    final request = await fitMessage(
      PromptMessage(seq: 0, isUser: true, text: text, tokens: await cost(text)),
      room: contextTokens - summaryTokens,
      cost: cost,
    );
    final g = _assistant.engine.generate(
      [EngineTurn('user', request.text)],
      maxTokens: summaryTokens,
      temperature: 0.2,
    );
    final summary = (await g.text.join()).trim();
    await g.done;
    if (summary.isEmpty) return;
    await _native.dbUpdateConversation(conv.id, {
      'summary': summary,
      'summarizedUpto': fold.last.seq + 1,
    });
  }

  /// Stops the reply in any phase: while it waits for another chat's
  /// reply, while the model loads, while it waits for the engine, or while
  /// it streams.
  Future<void> stop() async {
    unawaited(HapticFeedback.mediumImpact());
    _stopRequested = true;
    _queue.withdraw(this);
    await _generation?.cancel();
  }

  /// Replaces the last reply with a new one.
  Future<void> regenerate() async {
    if (busy || _messages.isEmpty) return;
    final last = _messages.first;
    if (last.role != Role.model) return;
    _messages.removeAt(0);
    notifyListeners();
    await _native.dbTruncate(_conversation!.id, last.seq);
    final lastUser = _messages.firstWhere((m) => m.role == Role.user);
    await _reply(recallQuery: lastUser.content);
  }

  /// Rewrites the last user message and answers it again.
  Future<void> editLast(String text) async {
    if (busy) return;
    final lastUser = _messages.where((m) => m.role == Role.user).firstOrNull;
    if (lastUser == null) return;
    _messages.removeWhere((m) => m.seq >= lastUser.seq);
    final docs = attachments.remove(lastUser.id) ?? const [];
    await _native.dbTruncate(
      _conversation!.id,
      lastUser.seq,
      keepImages: lastUser.imageIds,
      keepDocs: [for (final d in docs) d.id],
    );
    await send(text, const [], keepImageIds: lastUser.imageIds, docs: docs);
  }

  /// Answers again after an error.
  Future<void> retry() async {
    if (busy || _messages.isEmpty) return;
    final lastUser = _messages.firstWhere((m) => m.role == Role.user);
    error = null;
    await _reply(recallQuery: lastUser.content);
  }

  // A reply stopped by [dispose] (voice mode closed mid-answer) still winds
  // down afterwards; nobody listens any more, so its updates go nowhere.
  // [streaming] is left undisposed for the same reason; it holds nothing
  // but text.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRequested = true;
    _queue.withdraw(this);
    _generation?.cancel();
    super.dispose();
  }
}
