import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../assistant.dart';
import '../engine/engine_service.dart';
import '../memory/fact_suggester.dart';
import '../memory/memory_store.dart';
import '../platform/native.dart';
import 'chat_models.dart';
import 'chat_titler.dart';
import 'chat_store.dart';
import 'context_builder.dart';

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
}

enum ReplyPhase { idle, preparing, streaming }

/// An image attached in the composer, before it is stored.
class PendingImage {
  PendingImage(this.jpeg);
  final Uint8List jpeg;
}

/// One open chat: its messages (paged newest first), the reply being
/// generated, and the actions on it (send, stop, regenerate, edit).
class ChatSession extends ChangeNotifier {
  ChatSession({
    required NativeBridge native,
    required Assistant assistant,
    required ChatStore store,
    required MemoryStore memories,
    ConversationInfo? conversation,
    this.suggestFacts = true,
  }) : _native = native,
       _assistant = assistant,
       _store = store,
       _memories = memories,
       _conversation = conversation;

  static const int pageSize = 30;
  static const int replyTokens = 1024;

  final NativeBridge _native;
  final Assistant _assistant;
  final ChatStore _store;
  final MemoryStore _memories;

  /// Whether to ask the model for memory suggestions after each reply
  /// (voice mode has nowhere to show them).
  final bool suggestFacts;
  bool _disposed = false;

  ConversationInfo? _conversation;
  final List<ChatMessage> _messages = [];
  bool _hasMore = true;
  bool _loading = false;
  int _localSeq = -1;

  ReplyPhase phase = ReplyPhase.idle;
  final StreamingText streaming = StreamingText();
  Generation? _generation;
  String? error;

  /// Full text of the most recent reply, including the tail that may not
  /// have been published to [streaming] before the reply ended.
  String lastReply = '';

  /// Facts the model found in the user's last message, offered as
  /// suggestions; they arrive after the reply, when the engine is free.
  List<String> suggestions = const [];

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
      _messages.addAll(rows.map(ChatMessage.fromMap));
      _hasMore = rows.length == pageSize;
      notifyListeners();
    } finally {
      _loading = false;
    }
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

  Future<void> send(String text, List<PendingImage> images) async {
    if (busy || (text.trim().isEmpty && images.isEmpty)) return;
    _assistant.engine.preemptBackground();
    unawaited(HapticFeedback.lightImpact());
    error = null;
    suggestions = const [];
    final now = DateTime.now();
    // Optimistic: the message shows before anything is written.
    final optimistic = ChatMessage(
      id: -1,
      seq: _localSeq--,
      role: Role.user,
      content: text.trim(),
      imageIds: const [],
      created: now,
    );
    _messages.insert(0, optimistic);
    phase = ReplyPhase.preparing;
    streaming.value = '';
    notifyListeners();

    final convId = await _ensureConversation(text);
    final imageIds = <String>[];
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
    notifyListeners();
    unawaited(_store.upsert(convId));
    await _reply(recallQuery: text);
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
    final conv = _conversation!;
    phase = ReplyPhase.preparing;
    lastReply = '';
    notifyListeners();
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
      final recalled = await _recall(recallQuery, conv.id);
      final system = buildSystemPrompt(
        now: DateTime.now(),
        memories: [for (final m in _memories.items.take(40)) m.text],
        recalled: recalled,
        summary: fresh.summary,
      );
      final plan = planPrompt(
        system: system,
        history: [
          for (final m in history)
            PromptMessage(
              seq: m.seq,
              isUser: m.role == Role.user,
              text: m.content,
              imageCount: spec.vision ? _imagesSent(history, m) : 0,
            ),
        ],
        contextTokens: contextSize,
        replyTokens: replyTokens,
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
      final text = streaming.full.trim();
      if (text.isEmpty) return;
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
      final used = metrics.contextTokens ?? plan.estimatedTokens;
      if (shouldSummarize(usedTokens: used, contextTokens: contextSize)) {
        unawaited(_summarize());
      }
      final asked = history.lastWhere((m) => m.role == Role.user);
      unawaited(_afterReply(conv.id, history, asked.content, text));
    } catch (e) {
      error = e is PlatformException ? (e.message ?? e.code) : '$e';
    } finally {
      _generation = null;
      lastReply = streaming.full;
      phase = ReplyPhase.idle;
      streaming.value = '';
      streaming._buffer.clear();
      notifyListeners();
    }
  }

  /// Housekeeping the model does once the reply is in and the engine is
  /// free: naming a new chat and spotting facts worth remembering. Each
  /// step yields to the user's next message (see
  /// [EngineService.generateInBackground]).
  Future<void> _afterReply(
    String convId,
    List<ChatMessage> history,
    String asked,
    String reply,
  ) async {
    final engine = _assistant.engine;
    final firstUser = history.where((m) => m.role == Role.user).toList();
    if (firstUser.length == 1 && history.first.seq == 0) {
      final provisional = titleFrom(firstUser.single.content);
      final raw = await engine.generateInBackground(
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
    if (!suggestFacts || asked.trim().isEmpty || _disposed) return;
    final raw = await engine.generateInBackground(
      FactSuggester.prompt(asked),
      maxTokens: FactSuggester.maxTokens,
    );
    if (raw == null || _disposed || busy) return;
    suggestions = _memories.filterSuggestions(FactSuggester.parse(raw));
    notifyListeners();
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

  Future<List<String>> _recall(String query, String convId) async {
    if (query.trim().isEmpty) return const [];
    final rows = await _native.dbRecall(query, convId, 3);
    return [
      for (final r in rows)
        if ((r['score']! as num) > 2.0) _clip(r['content']! as String, 240),
    ];
  }

  static String _clip(String s, int max) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }

  /// Folds older turns into the conversation summary so the chat keeps its
  /// meaning while staying inside the model's context.
  Future<void> _summarize() async {
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
    final prompt = [
      for (final m in history)
        PromptMessage(seq: m.seq, isUser: m.role == Role.user, text: m.content),
    ];
    final fold = messagesToSummarize(prompt);
    if (fold.isEmpty) return;
    final g = _assistant.engine.generate(
      [EngineTurn('user', summarizePrompt(fresh.summary, fold))],
      maxTokens: 256,
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

  Future<void> stop() async {
    unawaited(HapticFeedback.mediumImpact());
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
    await _native.dbTruncate(_conversation!.id, lastUser.seq);
    await send(text, const []);
  }

  /// Answers again after an error.
  Future<void> retry() async {
    if (busy || _messages.isEmpty) return;
    final lastUser = _messages.firstWhere((m) => m.role == Role.user);
    error = null;
    await _reply(recallQuery: lastUser.content);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation?.cancel();
    streaming.dispose();
    super.dispose();
  }
}
