import '../platform/native.dart';
import '../model_output.dart';
import 'memory_store.dart';
import 'profile.dart';

/// The hidden prompts that let the model keep the user's profile, and the
/// structural validation of its answers. The model does all the judging,
/// in whatever language the user writes; this file only builds prompts and
/// treats every answer as untrusted data: anything that is not exactly the
/// shape asked for is rejected whole, never repaired.

/// Profile lines as the prompts show them, by section.
typedef ProfileText = Map<ProfileSection, List<String>>;

String _sectionList() => [
  for (final s in ProfileSection.values) '- ${s.name}: ${s.meaning}',
].join('\n');

String _sectionNames() => ProfileSection.values.map((s) => s.name).join('|');

String _showProfile(ProfileText profile) => [
  for (final s in ProfileSection.values) ...[
    '${s.name}:',
    if (profile[s]!.isEmpty) '  (empty)',
    for (final t in profile[s]!) '  - $t',
  ],
].join('\n');

/// Whitespace runs as one space, so a quote copied across a line break
/// still counts as copied.
String _squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A profile line from model output, or null when it is not one.
String? _line(Object? v) {
  if (v is! String) return null;
  final line = oneLine(v);
  if (line == null ||
      line.length < MemoryPolicy.minChars ||
      line.length > MemoryPolicy.maxChars) {
    return null;
  }
  return line;
}

/// Whether [lines] has no two lines that differ only in case or spacing.
bool _distinct(List<String> lines) =>
    lines.map((l) => _squash(l).toLowerCase()).toSet().length == lines.length;

enum GateKind {
  /// The user stated a lasting fact about themselves.
  stated,

  /// The user asked Aithra to remember something.
  asked,

  /// The message hints at a lasting fact without saying it.
  implied,
}

class GateVerdict {
  const GateVerdict(this.kind, this.quote);
  final GateKind kind;

  /// The user's own words that carry the fact, copied from their message.
  final String quote;
}

/// The first, cheap step after every message: does the user's message,
/// alone, say anything about the user worth keeping? Most messages do not,
/// and then nothing else runs. The model never sees the reply, so nothing
/// the assistant said or saw in an image can become a memory.
abstract final class MemoryGate {
  static const int maxTokens = 48;
  static const int maxMessageChars = 1500;

  static const String _instruction =
      'You decide whether a message a user sent to their assistant says '
      'something about the user that the assistant should remember in '
      'future, unrelated chats.\n'
      'Answer "stated" when the user states a lasting fact about themselves: '
      'their name, family, where they live, their job or studies, lasting '
      'interests, how they want answers, or projects that run for weeks.\n'
      'Answer "asked" when the user asks the assistant to remember '
      'something.\n'
      'Answer "implied" when the message strongly suggests such a lasting '
      'fact without stating it.\n'
      'Answer "none" for everything else, which is most messages: questions '
      'and requests, even questions about the user themselves such as what '
      'they are wearing or what they asked before; one-off tasks; plans for '
      'today; passing moods; general knowledge; other people; and health, '
      'money or beliefs unless the user asks to remember them.\n'
      'For any answer but "none", copy into "quote" the few words of the '
      'message that carry the fact, exactly as written.\n'
      'Reply with JSON only: {"keep": "none"} or '
      '{"keep": "stated|asked|implied", "quote": "..."}';

  static List<EngineTurn> prompt(String message) => [
    const EngineTurn('system', _instruction),
    EngineTurn(
      'user',
      'Message:\n"""\n${clipChars(message.trim(), maxMessageChars)}\n"""',
    ),
  ];

  /// The verdict in [raw], or null for "none" and for anything malformed.
  /// The quote must appear in [message] word for word: a quote the model
  /// made up, or took from anywhere else, is not the user's words.
  static GateVerdict? parse(String raw, String message) {
    final json = jsonObjectIn(raw);
    if (json == null) return null;
    final kind = switch (json['keep']) {
      'stated' => GateKind.stated,
      'asked' => GateKind.asked,
      'implied' => GateKind.implied,
      _ => null,
    };
    final quote = json['quote'];
    if (kind == null || quote is! String) return null;
    final q = _squash(quote);
    if (q.length < MemoryPolicy.minChars ||
        q.length > maxMessageChars ||
        !_squash(message).contains(q)) {
      return null;
    }
    return GateVerdict(kind, q);
  }
}

/// A validated rewrite of one profile section.
class SectionRewrite {
  const SectionRewrite(this.section, this.items);
  final ProfileSection section;
  final List<String> items;
}

/// Files new information into the profile by rewriting the one section it
/// belongs to: it corrects, merges or extends existing lines and adds a
/// line only when nothing covers it.
abstract final class ProfileRewriter {
  static const int maxTokens = 400;

  static const String _instruction =
      'You keep a short profile of the user that their private assistant '
      'reads at the start of every chat. Its sections:\n'
      '{sections}\n'
      'You get the profile and new information in the user\'s own words. '
      'Pick the one section it belongs to and write that section\'s full '
      'new list of lines. Update a line when the new information corrects '
      'or adds to it, merge lines that say the same thing, and add a line '
      'only when no line covers it. Copy every other line exactly. Each line '
      'is one short phrase in the third person, such as "Lives in Oslo", in '
      'the language of the user\'s words. At most {cap} lines.\n'
      'Reply with JSON only: {"section": "{names}", "items": ["..."]}';

  static List<EngineTurn> prompt({
    required ProfileText profile,
    required String words,
    required MemoryOrigin origin,
  }) {
    final how = origin == MemoryOrigin.asked
        ? 'The user asked the assistant to remember this'
        : 'The user said this about themselves';
    return [
      EngineTurn(
        'system',
        _instruction
            .replaceFirst('{sections}', _sectionList())
            .replaceFirst('{cap}', '${MemoryPolicy.sectionCap}')
            .replaceFirst('{names}', _sectionNames()),
      ),
      EngineTurn(
        'user',
        'Profile:\n${_showProfile(profile)}\n\n$how:\n"""\n'
            '${clipChars(words.trim(), MemoryGate.maxMessageChars)}\n"""',
      ),
    ];
  }

  /// The rewrite in [raw] if it passes every guard against [profile]: a
  /// known section; every line a short single line, none repeated; at most
  /// one line more than before and no more than the cap (unless the user
  /// already had more); and at most [MemoryPolicy.maxChanged] existing
  /// lines changed or dropped, so one message can never rewrite who the
  /// user is.
  static SectionRewrite? parse(String raw, ProfileText profile) {
    final json = jsonObjectIn(raw);
    if (json == null) return null;
    final section = ProfileSection.byName(json['section']);
    final list = json['items'];
    if (section == null || list is! List) return null;
    final items = <String>[];
    for (final v in list) {
      final line = _line(v);
      if (line == null) return null;
      items.add(line);
    }
    if (!_distinct(items)) return null;
    final old = profile[section]!;
    if (items.length > old.length + 1) return null;
    if (items.length > MemoryPolicy.sectionCap && items.length > old.length) {
      return null;
    }
    final changed = old.where((t) => !items.contains(t)).length;
    if (changed > MemoryPolicy.maxChanged) return null;
    return SectionRewrite(section, items);
  }
}

/// Turns words that only hint at something lasting into one suggested
/// profile line, which the user accepts or dismisses.
abstract final class SuggestionWriter {
  static const int maxTokens = 80;

  static const String _instruction =
      "Write what the user's words suggest about them as one short profile "
      'line in the third person, such as "Enjoys hiking", in the language of '
      'their words, and pick its section:\n'
      '{sections}\n'
      'Reply with JSON only: {"section": "{names}", "text": "..."}';

  static List<EngineTurn> prompt(String words) => [
    EngineTurn(
      'system',
      _instruction
          .replaceFirst('{sections}', _sectionList())
          .replaceFirst('{names}', _sectionNames()),
    ),
    EngineTurn(
      'user',
      'Words:\n"""\n'
          '${clipChars(words.trim(), MemoryGate.maxMessageChars)}\n"""',
    ),
  ];

  static (ProfileSection, String)? parse(String raw) {
    final json = jsonObjectIn(raw);
    if (json == null) return null;
    final section = ProfileSection.byName(json['section']);
    final text = _line(json['text']);
    if (section == null || text == null) return null;
    return (section, text);
  }
}

/// Sorts the memories kept before the profile existed into it, a batch at
/// a time: each old note goes into a section, merged with notes or earlier
/// lines that say the same, or is set aside when it is not a lasting fact
/// about the user.
abstract final class MemoryTidier {
  static const int batch = 12;
  static const int maxTokens = 640;

  static const String _instruction =
      'You are sorting notes an assistant kept about its user into a profile '
      'with these sections:\n'
      '{sections}\n'
      'Each numbered note (n1, n2, ...) must appear exactly once in your '
      'answer. Keep a note when it is a lasting fact about the user, in the '
      'section it belongs to; set it aside when it is not (a question the '
      'user asked, a one-off task, something about the assistant, a passing '
      'mood), still naming the section it would belong to. Merge notes that '
      'say the same thing into one line, and fold in an existing line '
      '(p1, p2, ...) that says the same thing. Lines are short phrases in '
      'the third person, in the language of the notes, at most {cap} per '
      'section.\n'
      'Reply with JSON only: {"keep": [{"section": "{names}", "text": "...", '
      '"from": ["n1", "p1"]}], "set_aside": [{"from": "n2", "section": '
      '"{names}"}]}';

  /// [notes] and [lines] pair each prompt key with its text.
  static List<EngineTurn> prompt({
    required List<(String, String)> notes,
    required List<(String, ProfileSection, String)> lines,
  }) => [
    EngineTurn(
      'system',
      _instruction
          .replaceFirst('{sections}', _sectionList())
          .replaceFirst('{cap}', '${MemoryPolicy.sectionCap}')
          .replaceAll('{names}', _sectionNames()),
    ),
    EngineTurn(
      'user',
      'Existing lines:\n'
          '${lines.isEmpty ? '(none)' : [for (final (k, s, t) in lines) '$k (${s.name}): $t'].join('\n')}'
          '\n\nNotes:\n'
          '${[for (final (k, t) in notes) '$k: $t'].join('\n')}',
    ),
  ];

  /// The batch in [raw] if it accounts for every note exactly once, names
  /// only the [notes] and [lines] it was shown (by prompt key to id), folds
  /// each line in at most once, and leaves no section above the cap that
  /// was not above it already ([sizes] are the sections' current sizes).
  static TidyBatch? parse(
    String raw, {
    required Map<String, String> notes,
    required Map<String, (ProfileSection, String)> lines,
    required Map<ProfileSection, int> sizes,
  }) {
    final json = jsonObjectIn(raw);
    if (json == null) return null;
    final keepJson = json['keep'];
    final asideJson = json['set_aside'];
    if (keepJson is! List || asideJson is! List) return null;
    final seenNotes = <String>{};
    final seenLines = <String>{};
    final after = {...sizes};
    final keep = <TidyLine>[];
    for (final v in keepJson) {
      if (v is! Map) return null;
      final section = ProfileSection.byName(v['section']);
      final text = _line(v['text']);
      final from = v['from'];
      if (section == null || text == null || from is! List || from.isEmpty) {
        return null;
      }
      final noteIds = <String>[];
      final absorbs = <String>[];
      for (final key in from) {
        if (notes[key] case final id? when seenNotes.add(key as String)) {
          noteIds.add(id);
        } else if (lines[key] case (final s, final id)?
            when seenLines.add(key as String)) {
          absorbs.add(id);
          after[s] = after[s]! - 1;
        } else {
          return null;
        }
      }
      if (noteIds.isEmpty) return null;
      after[section] = after[section]! + 1;
      keep.add((
        section: section,
        text: text,
        notes: noteIds,
        absorbs: absorbs,
      ));
    }
    final setAside = <({String note, ProfileSection section})>[];
    for (final v in asideJson) {
      if (v is! Map) return null;
      final key = v['from'];
      final section = ProfileSection.byName(v['section']);
      final id = notes[key];
      if (id == null || section == null || !seenNotes.add(key as String)) {
        return null;
      }
      setAside.add((note: id, section: section));
    }
    if (seenNotes.length != notes.length) return null;
    for (final s in ProfileSection.values) {
      if (after[s]! > MemoryPolicy.sectionCap && after[s]! > sizes[s]!) {
        return null;
      }
    }
    return (keep: keep, setAside: setAside);
  }
}
