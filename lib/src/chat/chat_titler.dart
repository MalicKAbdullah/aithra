import '../platform/native.dart';
import '../model_output.dart';

/// Asks the loaded model for a short chat title after the first exchange.
/// Until it answers, the chat is named after its first message
/// ([titleFrom]).
abstract final class ChatTitler {
  static const int maxTokens = 32;
  static const int maxWords = 6;
  static const int maxChars = 48;

  static List<EngineTurn> prompt(String userMessage, String reply) => [
    EngineTurn(
      'user',
      'Write a title of at most $maxWords words for this conversation, in '
          'its language. Reply with JSON only, in the form {"title": "..."}.'
          '\n\nUser:\n"""\n${clipChars(userMessage.trim(), 600)}\n"""\n\n'
          'Assistant:\n"""\n${clipChars(reply.trim(), 400)}\n"""',
    ),
  ];

  /// The title in a model reply, or null when the reply is not the JSON
  /// asked for or the title is empty or too long.
  static String? parse(String raw) {
    final t = jsonObjectIn(raw)?['title'];
    if (t is! String) return null;
    final line = oneLine(t);
    if (line == null || line.isEmpty) return null;
    if (line.split(' ').length > maxWords || line.length > maxChars) {
      return null;
    }
    return line;
  }
}
