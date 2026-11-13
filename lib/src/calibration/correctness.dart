/// A question with one known answer, used to catch backends that run fast
/// but produce wrong output (seen with some GPU drivers).
class Probe {
  const Probe(this.prompt, this.expected, this.pattern);

  final String prompt;

  /// Shown in reports.
  final String expected;
  final RegExp pattern;

  bool passes(String answer) => pattern.hasMatch(cleanAnswer(answer));
}

final List<Probe> probes = [
  Probe(
    'What is 17 + 25? Reply with only the number.',
    '42',
    RegExp(r'(^|[^0-9])42([^0-9]|$)'),
  ),
  Probe(
    'What is the capital of France? Reply with only the city name.',
    'Paris',
    RegExp(r'\bparis\b', caseSensitive: false),
  ),
  Probe(
    'What is 9 multiplied by 8? Reply with only the number.',
    '72',
    RegExp(r'(^|[^0-9])72([^0-9]|$)'),
  ),
];

/// Drops reasoning blocks some models emit before the answer.
String cleanAnswer(String raw) =>
    raw.replaceAll(RegExp(r'<think>[\s\S]*?(</think>|$)'), '').trim();

/// A fixed ~500-token English passage. Speed runs ask the model to repeat it,
/// which keeps decoding going for the whole token budget.
const String speedPassage =
    'The lighthouse at the end of the harbour was built in 1874 by a crew of '
    'twelve stonemasons who sailed in from the northern islands every spring. '
    'They cut granite from a quarry two miles inland, hauled each block to the '
    'shore on wooden sledges, and floated it across the bay on flat barges '
    'when the tide was high and the wind was calm. The work took six summers. '
    'In the first year a storm destroyed the scaffolding and two of the '
    'barges, and the masons spent the autumn rebuilding what the sea had '
    'taken. In the second year the foundation was finished and sealed with '
    'lime mortar mixed with crushed shells, a recipe the foreman had learned '
    'from his grandfather. By the fourth year the tower rose higher than the '
    'church steeple in the village, and children climbed the hill each '
    'evening to watch the last stones being lifted into place by a wooden '
    'crane powered by four horses walking in a circle. The lantern room was '
    'shipped from a foundry in the south: a cage of iron and brass holding a '
    'great lens made of hundreds of polished glass prisms. When the lamp was '
    'lit for the first time, on a cold night in late October, its beam could '
    'be seen from the fishing grounds twenty miles offshore. The first keeper '
    'was a former sailor named Elias Hart, who lived in the cottage at the '
    'base of the tower with his wife and three daughters. Every evening at '
    'dusk he climbed the one hundred and fourteen steps, trimmed the wick, '
    'polished the lens, and wound the clockwork that turned the light. Every '
    'morning at dawn he climbed them again to put the flame out and draw the '
    'curtains so that the sun would not crack the glass. He kept a logbook in '
    'which he recorded the weather, the ships that passed, and the birds that '
    'struck the windows during the autumn migration. The logbook still '
    'exists. It records forty years of storms, three shipwrecks, one royal '
    'visit, and the night in 1899 when the keeper rowed out alone through '
    'heavy surf to rescue the crew of a coal schooner that had run aground on '
    'the reef. Today the light is automatic and the cottage is a small '
    'museum, but the townspeople still say that on clear winter nights you '
    'can hear footsteps on the stairs.';

const String speedPrompt =
    '$speedPassage\n\nRepeat the passage above word for word, then continue '
    'the story in the same style.';
