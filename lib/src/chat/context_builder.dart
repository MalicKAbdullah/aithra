import 'dart:convert';

import '../model_output.dart';

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

/// A message from another chat, recalled for its meaning.
class RecalledMessage {
  const RecalledMessage({required this.fromUser, required this.text});

  /// Whether the user wrote it; otherwise it is one of Aithra's replies.
  final bool fromUser;
  final String text;
}

/// Everything the hidden system message carries besides who Aithra is. It
/// holds only what stays the same from turn to turn, so the engine can keep
/// the processed conversation and prefill just the new message; material
/// retrieved per turn goes with that turn (see [buildTurnContext]).
class SystemContext {
  const SystemContext({
    required this.now,
    this.aboutUser = '',
    this.replyStyle = '',
    this.memories = const [],
    this.summary,
  });

  final DateTime now;

  /// The user's custom instructions.
  final String aboutUser;
  final String replyStyle;

  /// Long-term memories, most important first.
  final List<String> memories;

  /// The summary of this chat's earlier turns.
  final String? summary;

  /// A smaller version for a system message over its budget, or null when
  /// nothing optional is left. Memories go first, from the end of the list
  /// (half at a time), then the custom instructions are shortened; this
  /// chat's own summary is always kept.
  SystemContext? shed() {
    if (memories.isNotEmpty) {
      return _copy(memories: memories.sublist(0, memories.length ~/ 2));
    }
    if (aboutUser.length > _minInstructionChars ||
        replyStyle.length > _minInstructionChars) {
      String half(String s) =>
          s.length > _minInstructionChars ? clipChars(s, s.length ~/ 2) : s;
      return _copy(aboutUser: half(aboutUser), replyStyle: half(replyStyle));
    }
    return null;
  }

  static const _minInstructionChars = 100;

  SystemContext _copy({
    String? aboutUser,
    String? replyStyle,
    List<String>? memories,
  }) => SystemContext(
    now: now,
    aboutUser: aboutUser ?? this.aboutUser,
    replyStyle: replyStyle ?? this.replyStyle,
    memories: memories ?? this.memories,
    summary: summary,
  );
}

/// The share of the context the system message may take, so memories and
/// instructions never crowd out the conversation itself.
int systemBudget(int contextTokens) => (contextTokens * 0.3).floor();

/// Builds the system message for [context], shedding optional parts (see
/// [SystemContext.shed]) until it costs at most [budget] tokens as measured
/// by [cost]. [firstCost] is the cost of the full message when the caller
/// already measured it.
Future<String> fitSystemPrompt(
  SystemContext context, {
  required int budget,
  required int firstCost,
  required Future<int> Function(String text) cost,
}) async {
  var current = context;
  var text = buildSystemPrompt(current);
  var tokens = firstCost;
  while (tokens > budget) {
    final smaller = current.shed();
    if (smaller == null) break;
    current = smaller;
    text = buildSystemPrompt(current);
    tokens = await cost(text);
  }
  return text;
}

/// The system message: who Aithra is, the user's custom instructions, what
/// it remembers about the user, and the summary of this chat's earlier
/// turns.
String buildSystemPrompt(SystemContext context) {
  final SystemContext(:now, :aboutUser, :replyStyle, :memories, :summary) =
      context;
  final b = StringBuffer()
    ..writeln(
      'You are Aithra, a helpful assistant that runs entirely on the '
      "user's phone. Be concise and friendly. Use Markdown when it helps. "
      r'Write mathematics in LaTeX: $…$ inline, and $$…$$ on lines of its '
      'own for display equations.',
    )
    ..writeln(
      'To graph functions of x, write a ```plot block holding JSON like '
      '{"fn":["sin(x)","x^2/4"],"x":[-6.28,6.28]}. To chart data, write a '
      '```chart block like {"type":"bar","title":"Sales","labels":["Q1",'
      '"Q2"],"series":[{"name":"2025","data":[3,5]}]}; type is bar, line, '
      'pie or scatter (scatter data is [x,y] pairs).',
    )
    ..writeln('Today is ${now.year}-${_two(now.month)}-${_two(now.day)}.');
  if (aboutUser.trim().isNotEmpty || replyStyle.trim().isNotEmpty) {
    b.writeln(
      "\nThe user's custom instructions. Follow them unless they conflict "
      'with being helpful, honest and safe.',
    );
    if (aboutUser.trim().isNotEmpty) {
      b
        ..writeln('What the user wants you to know about them:')
        ..writeln(aboutUser.trim());
    }
    if (replyStyle.trim().isNotEmpty) {
      b
        ..writeln('How the user wants you to respond:')
        ..writeln(replyStyle.trim());
    }
  }
  if (memories.isNotEmpty) {
    b.writeln('\nWhat you know about the user:');
    for (final m in memories) {
      b.writeln('- $m');
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

/// Material for the newest user turn only: the profile lines picked for
/// this message ([related]) and messages [recalled] from other chats.
/// Empty when there is neither.
String buildTurnContext({
  List<String> related = const [],
  List<RecalledMessage> recalled = const [],
}) {
  if (related.isEmpty && recalled.isEmpty) return '';
  final b = StringBuffer()
    ..writeln('(Context for this message; the user has not repeated it.');
  if (related.isNotEmpty) {
    b.writeln('More of what you know about the user:');
    for (final m in related) {
      b.writeln('- $m');
    }
  }
  if (recalled.isNotEmpty) {
    b.writeln('Possibly relevant messages from earlier chats:');
    for (final r in recalled) {
      b.writeln(
        '- ${r.fromUser ? 'The user wrote' : 'You replied'}: ${r.text}',
      );
    }
  }
  b.write(')');
  return b.toString();
}

/// The largest [buildTurnContext] that costs at most [room] tokens by
/// [cost], and that cost; the user's message is fitted first, so this only
/// uses what it leaves. Recalled messages go first, from the end (the least
/// related), then profile lines from the end.
Future<({String text, int tokens})> fitTurnContext({
  required List<String> related,
  required List<RecalledMessage> recalled,
  required int room,
  required Future<int> Function(String text) cost,
}) async {
  var r = related;
  var m = recalled;
  while (r.isNotEmpty || m.isNotEmpty) {
    final text = buildTurnContext(related: r, recalled: m);
    final tokens = await cost(text);
    if (tokens <= room) return (text: text, tokens: tokens);
    if (m.isNotEmpty) {
      m = m.sublist(0, m.length - 1);
    } else {
      r = r.sublist(0, r.length - 1);
    }
  }
  return (text: '', tokens: 0);
}

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

/// The hidden user turn that asks for the rest of a reply cut off at the
/// reply-token limit. What it writes is appended to the stored reply as is,
/// so the model is the one to decide how the two join.
const continuePrompt =
    'Your last reply was cut off by a length limit. Continue it exactly '
    'where it stopped: start with the very next characters (a leading '
    'space only if one belongs there), do not repeat anything, and add no '
    'preamble.';

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
