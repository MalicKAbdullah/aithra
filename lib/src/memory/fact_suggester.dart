import '../platform/native.dart';
import '../model_output.dart';

/// Asks the loaded model which durable facts about the user their message
/// states. The model does the understanding, in whatever language the user
/// writes; this file only builds the prompt and validates the reply.
/// Suggestions are offered to the user and never saved on their own.
abstract final class FactSuggester {
  static const int maxTokens = 96;
  static const int maxFacts = 3;
  static const int maxFactChars = 120;

  /// The user's message is cut to this many characters in the prompt.
  static const int maxInputChars = 1500;

  static List<EngineTurn> prompt(String userMessage) => [
    EngineTurn(
      'user',
      'List durable facts about the user that this message states: stable '
          'personal details worth remembering in future chats, such as their '
          'name, family, where they live, their work, lasting preferences, '
          'allergies or important dates. Leave out passing feelings, opinions '
          'about one-off things, questions, requests and anything that is '
          'not about the user. Write each fact as a short sentence in the '
          'third person, in the language of the message.\n'
          'Reply with JSON only, in the form {"facts": ["..."]}, and '
          '{"facts": []} when there are none.\n\n'
          'Message:\n"""\n${clipChars(userMessage.trim(), maxInputChars)}\n"""',
    ),
  ];

  /// The valid, distinct facts in a model reply; empty when the reply is
  /// not the JSON asked for.
  static List<String> parse(String raw) {
    final facts = jsonObjectIn(raw)?['facts'];
    if (facts is! List) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final f in facts) {
      if (f is! String) continue;
      final line = oneLine(f);
      if (line == null || line.length < 3 || line.length > maxFactChars) {
        continue;
      }
      if (seen.add(line.toLowerCase())) out.add(line);
      if (out.length == maxFacts) break;
    }
    return out;
  }
}
