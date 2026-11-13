/// Rough token count without a tokenizer: English averages a little over
/// three characters per token for these models; each message adds template
/// tokens and each image its vision tokens.
int estimateTokens(String text, {int images = 0}) =>
    (text.length / 3.2).ceil() + 6 + images * imageTokens;

const int imageTokens = 300;

/// One message of history as the prompt builder sees it.
class PromptMessage {
  const PromptMessage({
    required this.seq,
    required this.isUser,
    required this.text,
    this.imageCount = 0,
  });

  final int seq;
  final bool isUser;
  final String text;
  final int imageCount;
}

class PromptPlan {
  const PromptPlan(this.system, this.messages, this.estimatedTokens);

  final String system;

  /// The suffix of the history that fits, oldest first.
  final List<PromptMessage> messages;
  final int estimatedTokens;
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

/// Keeps the newest messages that fit in [contextTokens] minus room for the
/// reply. The newest message is always kept.
PromptPlan planPrompt({
  required String system,
  required List<PromptMessage> history,
  required int contextTokens,
  required int replyTokens,
}) {
  final budget = contextTokens - replyTokens;
  var used = estimateTokens(system);
  final kept = <PromptMessage>[];
  for (final m in history.reversed) {
    final cost = estimateTokens(m.text, images: m.imageCount);
    if (kept.isNotEmpty && used + cost > budget) break;
    kept.add(m);
    used += cost;
  }
  return PromptPlan(system, kept.reversed.toList(), used);
}

/// Whether the chat should summarize its older turns now: it fills more
/// than [threshold] of the context.
bool shouldSummarize({
  required int usedTokens,
  required int contextTokens,
  double threshold = 0.7,
}) => usedTokens > contextTokens * threshold;

/// Which messages to fold into the summary: everything but the last
/// [keepRecent], starting after what is already summarized.
List<PromptMessage> messagesToSummarize(
  List<PromptMessage> history, {
  int keepRecent = 6,
}) => history.length <= keepRecent
    ? const []
    : history.sublist(0, history.length - keepRecent);

String summarizePrompt(String? previous, List<PromptMessage> messages) {
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
