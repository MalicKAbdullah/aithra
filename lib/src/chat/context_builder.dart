import 'dart:convert';

/// One message of history as the prompt builder sees it.
class PromptMessage {
  const PromptMessage({
    required this.seq,
    required this.isUser,
    required this.text,
    required this.tokens,
    this.imageCount = 0,
  });

  final int seq;
  final bool isUser;
  final String text;
  final int imageCount;

  /// Tokens this message adds to a prompt: exact under the loaded model's
  /// tokenizer, or [estimateTokens] when the runtime has none.
  final int tokens;

  PromptMessage withText(String text, int tokens) => PromptMessage(
    seq: seq,
    isUser: isUser,
    text: text,
    tokens: tokens,
    imageCount: imageCount,
  );
}

class PromptPlan {
  const PromptPlan(this.system, this.messages, this.promptTokens);

  final String system;

  /// The suffix of the history that fits, oldest first.
  final List<PromptMessage> messages;

  /// Prompt size, exact or estimated like the messages' counts.
  final int promptTokens;
}

/// The system message: who Aithra is, what it remembers about the user,
/// snippets recalled from other chats, and the summary of this chat's
/// earlier turns.
String buildSystemPrompt({
  required DateTime now,
  required List<String> memories,
  required List<String> recalled,
  required String? summary,
}) {
  final b = StringBuffer()
    ..writeln(
      'You are Aithra, a helpful assistant that runs entirely on the '
      "user's phone. Be concise and friendly. Use Markdown when it helps.",
    )
    ..writeln('Today is ${now.year}-${_two(now.month)}-${_two(now.day)}.');
  if (memories.isNotEmpty) {
    b.writeln('\nWhat you know about the user:');
    for (final m in memories) {
      b.writeln('- $m');
    }
  }
  if (recalled.isNotEmpty) {
    b.writeln('\nPossibly relevant notes from earlier chats:');
    for (final r in recalled) {
      b.writeln('- $r');
    }
  }
  if (summary != null && summary.isNotEmpty) {
    b
      ..writeln('\nSummary of the earlier part of this conversation:')
      ..writeln(summary);
  }
  return b.toString().trimRight();
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Prompt tokens per UTF-8 byte when nothing has been measured: tokenizers
/// with byte fallback (SentencePiece, BPE) never produce more tokens than a
/// text has bytes, so this bound cannot underestimate.
const double byteBoundTokensPerByte = 1;

/// Tokens [text] costs on a runtime without a tokenizer, from the highest
/// prompt-tokens-per-byte ratio the model has shown on this phone. Each
/// measured ratio covers a whole prompt, template markup included, so
/// estimates for single messages err high.
int estimateTokens(String text, double tokensPerByte) =>
    (utf8.encode(text).length * tokensPerByte).ceil();

/// [text] with its middle replaced by a marker so that about [keepChars]
/// characters remain: a long paste usually carries its point (and the
/// question about it) at the start and the end.
String clipMiddle(String text, int keepChars) {
  final head = keepChars ~/ 2;
  final tail = keepChars - head;
  final skipped = text.length - keepChars;
  return '${text.substring(0, head)}\n\n[… $skipped characters left out to '
      "fit the model's memory …]\n\n${text.substring(text.length - tail)}";
}

/// Shortens [newest] until it costs at most [room] tokens, measuring each
/// attempt with [cost]. Returns it unchanged when it already fits.
Future<PromptMessage> fitMessage(
  PromptMessage newest, {
  required int room,
  required Future<int> Function(String text) cost,
}) async {
  if (room <= 0) {
    throw StateError(
      "Your memories and this chat's summary fill the model's context. "
      'Remove some memories or start a new chat.',
    );
  }
  var fitted = newest;
  var keep = newest.text.length;
  while (fitted.tokens > room) {
    // Proportional to the overshoot, and always shorter than the last
    // attempt, so the loop ends even where the marker's own cost dominates.
    final proportional = (keep * room / fitted.tokens).floor();
    keep = proportional < keep ? proportional : keep - 1;
    if (keep <= 0) {
      throw StateError("This message cannot fit in the model's context.");
    }
    final text = clipMiddle(newest.text, keep);
    fitted = newest.withText(text, await cost(text));
  }
  return fitted;
}

/// Keeps the newest messages that fit in [contextTokens] minus room for the
/// reply: [systemTokens] for the system turn, [overheadTokens] for the rest
/// of the prompt and each message's [PromptMessage.tokens]. The newest
/// message is always kept; [fitMessage] makes sure it fits on its own.
PromptPlan planPrompt({
  required String system,
  required List<PromptMessage> history,
  required int contextTokens,
  required int replyTokens,
  required int systemTokens,
  required int overheadTokens,
}) {
  final budget = contextTokens - replyTokens;
  var used = systemTokens + overheadTokens;
  final kept = <PromptMessage>[];
  for (final m in history.reversed) {
    final cost = m.tokens;
    if (kept.isNotEmpty && used + cost > budget) break;
    kept.add(m);
    used += cost;
  }
  return PromptPlan(system, kept.reversed.toList(), used);
}

/// Whether the chat should fold its older turns into the summary now, from
/// [usedTokens], the context the engine reported for the last turn: the
/// next turn needs that much again plus a new message and [replyTokens],
/// so summarizing starts once that would pass [threshold] of the context.
bool shouldSummarize({
  required int usedTokens,
  required int contextTokens,
  required int replyTokens,
  double threshold = 0.8,
}) => usedTokens + replyTokens > contextTokens * threshold;

/// Which messages to fold into the summary: everything but the last
/// [keepRecent], starting after what is already summarized.
List<T> messagesToSummarize<T>(List<T> history, {int keepRecent = 6}) =>
    history.length <= keepRecent
    ? const []
    : history.sublist(0, history.length - keepRecent);

String summarizePrompt(
  String? previous,
  List<({bool isUser, String text})> messages,
) {
  final b = StringBuffer()
    ..writeln(
      'Summarize this conversation between a user and an assistant in '
      'at most 120 words. Keep facts about the user, decisions, names, '
      'numbers and open questions. Write plain sentences, no preamble.',
    );
  if (previous != null && previous.isNotEmpty) {
    b
      ..writeln('\nEarlier summary:')
      ..writeln(previous);
  }
  b.writeln('\nConversation:');
  for (final m in messages) {
    b.writeln('${m.isUser ? 'User' : 'Assistant'}: ${m.text}');
  }
  return b.toString();
}
