/// A small Markdown parser for chat replies: fenced code, display math,
/// headings, lists, quotes, rules and paragraphs, with bold/italic/code/link
/// and LaTeX math inlines. It is tolerant of half-written input, because
/// replies are parsed while they stream: an unclosed code fence is still a
/// code block, and math whose closing delimiter has not arrived yet stays
/// plain text until it does.
sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdCode extends MdBlock {
  const MdCode(this.language, this.code, {required this.closed});
  final String language;
  final String code;
  final bool closed;
}

class MdListItem extends MdBlock {
  const MdListItem(this.text, {required this.marker, required this.indent});

  /// "•" for bullets, "3." for numbered items.
  final String marker;
  final int indent;
  final String text;
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

class MdRule extends MdBlock {
  const MdRule();
}

/// A display equation on lines of its own: `$$ … $$` or `\[ … \]`.
class MdMath extends MdBlock {
  const MdMath(this.tex);
  final String tex;
}

final _fence = RegExp(r'^\s*(```|~~~)\s*([\w+#.-]*)\s*$');
final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');

/// The display math starting at [lines] `[start]`, as the equation and the
/// index of its last line; null when the line does not open one or its
/// closing delimiter has not arrived (the lines then read as text).
(String, int)? _displayMath(List<String> lines, int start) {
  final first = lines[start].trimLeft();
  final String close;
  if (first.startsWith(r'$$')) {
    close = r'$$';
  } else if (first.startsWith(r'\[')) {
    close = r'\]';
  } else {
    return null;
  }
  final body = StringBuffer();
  var rest = first.substring(2);
  for (var i = start; i < lines.length; i++) {
    if (i > start) rest = lines[i];
    final end = rest.indexOf(close);
    if (end >= 0) {
      // Text after the closer means the equation sits inside a paragraph.
      if (rest.substring(end + close.length).trim().isNotEmpty) return null;
      body.write(rest.substring(0, end));
      final tex = body.toString().trim();
      return tex.isEmpty ? null : (tex, i);
    }
    body.writeln(rest);
  }
  return null;
}

List<MdBlock> parseMarkdown(String source) {
  final blocks = <MdBlock>[];
  final lines = source.split('\n');
  final para = <String>[];

  void flush() {
    if (para.isNotEmpty) {
      blocks.add(MdParagraph(para.join('\n')));
      para.clear();
    }
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final fence = _fence.firstMatch(line);
    if (fence != null) {
      flush();
      final code = <String>[];
      var closed = false;
      for (i++; i < lines.length; i++) {
        if (lines[i].trim() == fence.group(1)) {
          closed = true;
          break;
        }
        code.add(lines[i]);
      }
      blocks.add(MdCode(fence.group(2)!, code.join('\n'), closed: closed));
      continue;
    }
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    final math = _displayMath(lines, i);
    if (math != null) {
      flush();
      blocks.add(MdMath(math.$1));
      i = math.$2;
      continue;
    }
    final h = _heading.firstMatch(line);
    if (h != null) {
      flush();
      blocks.add(MdHeading(h.group(1)!.length, h.group(2)!.trim()));
      continue;
    }
    if (_rule.hasMatch(line)) {
      flush();
      blocks.add(const MdRule());
      continue;
    }
    final b = _bullet.firstMatch(line);
    if (b != null) {
      flush();
      blocks.add(
        MdListItem(b.group(2)!, marker: '•', indent: b.group(1)!.length ~/ 2),
      );
      continue;
    }
    final n = _numbered.firstMatch(line);
    if (n != null) {
      flush();
      blocks.add(
        MdListItem(
          n.group(3)!,
          marker: '${n.group(2)}.',
          indent: n.group(1)!.length ~/ 2,
        ),
      );
      continue;
    }
    if (line.startsWith('>')) {
      flush();
      blocks.add(MdQuote(line.replaceFirst(RegExp(r'^>\s?'), '')));
      continue;
    }
    para.add(line);
  }
  flush();
  return blocks;
}

enum InlineStyle {
  plain,
  bold,
  italic,
  boldItalic,
  code,
  link,

  /// LaTeX set in the line: `$…$` or `\(…\)`.
  math,

  /// LaTeX set as a display equation within a paragraph: `$$…$$` or `\[…\]`.
  displayMath,
}

class MdSpan {
  const MdSpan(this.text, this.style);
  final String text;
  final InlineStyle style;

  @override
  bool operator ==(Object other) =>
      other is MdSpan && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);

  @override
  String toString() => '${style.name}("$text")';
}

final _emphasis = RegExp(
  r'(\*\*\*[^*]+\*\*\*)|(\*\*[^*]+\*\*|__[^_]+__)|(\*[^*\s][^*]*\*|_[^_\s][^_]*_)|(\[[^\]]+\]\([^)]+\))',
);

/// Inline Markdown in [text]. Code spans and math are found first, so the
/// `*`, `_` and `$` inside them keep their literal meaning there.
List<MdSpan> parseInline(String text) {
  final spans = <MdSpan>[];
  var plainFrom = 0;
  var i = 0;

  void literalUpTo(int end) {
    if (end > plainFrom) {
      _addEmphasis(spans, text.substring(plainFrom, end));
    }
  }

  void take(int start, int end, MdSpan span) {
    literalUpTo(start);
    spans.add(span);
    i = plainFrom = end;
  }

  while (i < text.length) {
    final ch = text.codeUnitAt(i);
    if (ch == _backtick) {
      final close = text.indexOf('`', i + 1);
      if (close > i + 1) {
        take(
          i,
          close + 1,
          MdSpan(text.substring(i + 1, close), InlineStyle.code),
        );
        continue;
      }
    } else if (ch == _backslash && i + 1 < text.length) {
      final next = text[i + 1];
      if (next == '(' || next == '[') {
        final closer = next == '(' ? r'\)' : r'\]';
        final close = text.indexOf(closer, i + 2);
        final tex = close < 0 ? '' : text.substring(i + 2, close).trim();
        if (tex.isNotEmpty) {
          final style = next == '('
              ? InlineStyle.math
              : InlineStyle.displayMath;
          take(i, close + 2, MdSpan(tex, style));
          continue;
        }
      }
      // An escaped character (`\$` above all) is never a delimiter.
      i += 2;
      continue;
    } else if (ch == _dollar) {
      final end = _mathEnd(text, i);
      if (end != null) {
        final display = text.startsWith(r'$$', i);
        final width = display ? 2 : 1;
        take(
          i,
          end + width,
          MdSpan(
            text.substring(i + width, end).trim(),
            display ? InlineStyle.displayMath : InlineStyle.math,
          ),
        );
        continue;
      }
      // A `$$` that does not open math is skipped whole, so its second `$`
      // cannot open inline math.
      i += text.startsWith(r'$$', i) ? 2 : 1;
      continue;
    }
    i++;
  }
  literalUpTo(text.length);
  return spans;
}

const _backtick = 0x60;
const _backslash = 0x5C;
const _dollar = 0x24;

bool _isSpace(String c) => c.trim().isEmpty;
bool _isDigit(String c) => c.compareTo('0') >= 0 && c.compareTo('9') <= 0;

/// Where the math opened by the `$` or `$$` at [open] closes, or null when
/// it is not math. Follows the usual Markdown rules that keep prices from
/// reading as math: the opening `$` is not followed by a space, the closing
/// one is the next unescaped `$`, is not preceded by a space and is not
/// followed by a digit ("$5 and $10" stays text).
int? _mathEnd(String text, int open) {
  if (text.startsWith(r'$$', open)) {
    final close = _unescaped(text, r'$$', open + 2);
    if (close == null || text.substring(open + 2, close).trim().isEmpty) {
      return null;
    }
    return close;
  }
  final after = open + 1;
  if (after >= text.length || _isSpace(text[after])) return null;
  final close = _unescaped(text, r'$', after);
  if (close == null || close == after) return null;
  if (_isSpace(text[close - 1])) return null;
  if (close + 1 < text.length && _isDigit(text[close + 1])) return null;
  return close;
}

/// The index of the next [token] at or after [from] that no backslash
/// escapes.
int? _unescaped(String text, String token, int from) {
  var at = text.indexOf(token, from);
  while (at >= 0) {
    var slashes = 0;
    while (at - slashes - 1 >= 0 &&
        text.codeUnitAt(at - slashes - 1) == _backslash) {
      slashes++;
    }
    if (slashes.isEven) return at;
    at = text.indexOf(token, at + 1);
  }
  return null;
}

void _addEmphasis(List<MdSpan> spans, String raw) {
  // Outside math and code a backslash-escaped dollar is a dollar sign.
  final text = raw.replaceAll(r'\$', r'$');
  var last = 0;
  for (final m in _emphasis.allMatches(text)) {
    if (m.start > last) {
      spans.add(MdSpan(text.substring(last, m.start), InlineStyle.plain));
    }
    final t = m.group(0)!;
    if (m.group(1) != null) {
      spans.add(MdSpan(t.substring(3, t.length - 3), InlineStyle.boldItalic));
    } else if (m.group(2) != null) {
      spans.add(MdSpan(t.substring(2, t.length - 2), InlineStyle.bold));
    } else if (m.group(3) != null) {
      spans.add(MdSpan(t.substring(1, t.length - 1), InlineStyle.italic));
    } else {
      spans.add(MdSpan(t.substring(1, t.indexOf(']')), InlineStyle.link));
    }
    last = m.end;
  }
  if (last < text.length) {
    spans.add(MdSpan(text.substring(last), InlineStyle.plain));
  }
}

/// [source] as one line of plain text for a list preview: Markdown syntax
/// removed, code kept as its text, whitespace collapsed.
String plainPreview(String source) {
  final parts = <String>[
    for (final b in parseMarkdown(source))
      switch (b) {
        MdHeading(:final text) ||
        MdParagraph(:final text) ||
        MdListItem(:final text) ||
        MdQuote(:final text) => parseInline(text).map((s) => s.text).join(),
        MdCode(:final code) || MdMath(tex: final code) => code,
        MdRule() => '',
      },
  ];
  return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
