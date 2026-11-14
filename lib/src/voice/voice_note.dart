import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../assistant.dart';
import '../chat/chat_models.dart';
import '../chat/chat_session.dart';
import '../chat/chat_store.dart';
import '../chat/context_builder.dart';
import '../engine/engine_service.dart';
import '../platform/native.dart';

/// What the model can do with a dictated note.
enum NoteAction {
  cleanUp('Clean up', 'Cleaned up'),
  summarise('Summarise', 'Summary'),
  actionItems('Action items', 'Action items');

  const NoteAction(this.label, this.heading);

  /// The chip.
  final String label;

  /// Above the result.
  final String heading;
}

/// The fixed request for [action] on [note].
String notePrompt(NoteAction action, String note) {
  final task = switch (action) {
    NoteAction.cleanUp =>
      'Rewrite it as clean, readable text: fix punctuation, grammar and '
          'words the speech recognizer got wrong, drop filler words and '
          'repetitions, and break it into paragraphs. Keep the meaning and '
          'as much of the wording as you can. Reply with the text only.',
    NoteAction.summarise =>
      'Summarise it in a few short bullet points. Reply with the summary '
          'only.',
    NoteAction.actionItems =>
      'List the things to do that it mentions, one bullet each, starting '
          'with a verb and with any person or date it gives. If it mentions '
          'none, say so in one sentence.',
  };
  return 'Here is a voice note I dictated. $task Write in the language of '
      'the note.\n\nVoice note:\n"""\n${note.trim()}\n"""';
}

/// Runs one [NoteAction] at a time on the loaded model and streams its
/// output into [output].
class VoiceNoteRunner extends ChangeNotifier {
  VoiceNoteRunner(this._assistant);

  final Assistant _assistant;
  Generation? _generation;
  int _run = 0;

  NoteAction? action;
  final StreamingText output = StreamingText();
  bool running = false;
  String? error;

  /// The text of the finished result, or null while there is none.
  String? result;

  Future<void> run(NoteAction next, String note) async {
    await stop();
    final run = ++_run;
    action = next;
    result = null;
    error = null;
    running = true;
    output.value = '';
    notifyListeners();
    try {
      final prepared = await _assistant.prepare();
      if (prepared == null) {
        throw StateError('No model is ready. Download one in Models.');
      }
      final (spec, _) = prepared;
      final engine = _assistant.engine;
      final text = notePrompt(next, note);
      Future<int> cost(String t) async =>
          (await engine.countTokens([EngineTurn('user', t)])).counts?.single ??
          estimateTokens(t, _assistant.tokensPerByte(spec));
      // A long note is shortened in the middle like any long message.
      final fitted = await fitMessage(
        PromptMessage(
          seq: 0,
          isUser: true,
          text: text,
          tokens: await cost(text),
        ),
        room: engine.contextSize! - ChatSession.replyTokens,
        cost: cost,
      );
      if (run != _run) return;
      final g = _generation = engine.generate(
        [EngineTurn('user', fitted.text)],
        maxTokens: ChatSession.replyTokens,
        temperature: 0.3,
      );
      await for (final chunk in g.text) {
        if (run == _run) output.add(chunk);
      }
      await g.done;
      if (run != _run) return;
      result = output.full.trim();
    } catch (e) {
      if (run != _run) return;
      error = e is PlatformException ? (e.message ?? e.code) : '$e';
    }
    running = false;
    _generation = null;
    notifyListeners();
  }

  Future<void> stop() async {
    final g = _generation;
    if (!running) return;
    _run++;
    running = false;
    _generation = null;
    result = output.full.trim().isEmpty ? null : output.full.trim();
    notifyListeners();
    await g?.cancel();
  }

  @override
  void dispose() {
    _run++;
    unawaited(_generation?.cancel());
    super.dispose();
  }
}

/// Saves [note] as a new chat: the note as the user's message and, when
/// there is one, [result] as Aithra's reply. Returns the new chat.
Future<ConversationInfo> saveNoteAsChat({
  required NativeBridge native,
  required ChatStore chats,
  required String note,
  String? result,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final id = DateTime.now().microsecondsSinceEpoch.toString();
  await native.dbCreateConversation(id, titleFrom(note), now);
  await native.dbAddMessage(
    convId: id,
    role: 'user',
    content: note.trim(),
    images: const [],
    stats: null,
    now: now,
  );
  if (result != null && result.trim().isNotEmpty) {
    await native.dbAddMessage(
      convId: id,
      role: 'model',
      content: result.trim(),
      images: const [],
      stats: null,
      now: now + 1,
    );
  }
  await chats.upsert(id);
  return ConversationInfo.fromMap((await native.dbConversation(id))!);
}
