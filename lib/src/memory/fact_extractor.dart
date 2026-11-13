/// Suggests facts worth remembering from something the user wrote, by
/// matching common first-person statements. Suggestions are only offered;
/// nothing is saved until the user accepts.
List<String> suggestFacts(String message) {
  final out = <String>[];
  for (final sentence in message.split(RegExp(r'(?<=[.!?\n])\s+'))) {
    final s = sentence.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    for (final rule in _rules) {
      final m = rule.pattern.firstMatch(s);
      if (m != null) {
        final value = m.group(m.groupCount)!.trim();
        if (value.isNotEmpty && value.length <= 80) {
          out.add(rule.render(m, value));
        }
        break;
      }
    }
  }
  return out.toSet().toList();
}

class _Rule {
  _Rule(String pattern, this.render)
    : pattern = RegExp(pattern, caseSensitive: false);

  final RegExp pattern;
  final String Function(RegExpMatch m, String value) render;
}

final List<_Rule> _rules = [
  _Rule(r'\bremember (?:that )?(.+)', (_, v) => _capitalize(v)),
  _Rule(r"\bmy name is ([\w' -]+)", (_, v) => "User's name is $v"),
  _Rule(r"\bcall me ([\w' -]+)", (_, v) => 'User likes to be called $v'),
  _Rule(
    r'\bmy (wife|husband|partner|son|daughter|mother|father|mom|dad|brother|sister|dog|cat)(?:.s name)? is (?:called |named )?(.+)',
    (m, v) => "User's ${m.group(1)!.toLowerCase()} is $v",
  ),
  _Rule(r'\bmy birthday is (.+)', (_, v) => "User's birthday is $v"),
  _Rule(r"\bi(?: am|'m) allergic to (.+)", (_, v) => 'User is allergic to $v'),
  _Rule(r'\bi live in (.+)', (_, v) => 'User lives in $v'),
  _Rule(r"\bi(?: am|'m) from (.+)", (_, v) => 'User is from $v'),
  _Rule(
    r'\bi work (as|at|in|for) (.+)',
    (m, v) => 'User works ${m.group(1)!.toLowerCase()} $v',
  ),
  _Rule(
    r'\bi (?:really )?(like|love|enjoy|prefer|hate|dislike) (.+)',
    (m, v) => 'User ${m.group(1)!.toLowerCase()}s $v',
  ),
  _Rule(r"\bi(?: am|'m) (?:a|an) ([\w -]+)", (_, v) => 'User is a $v'),
];

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
