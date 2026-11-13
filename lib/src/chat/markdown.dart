/// A small Markdown parser for chat replies: fenced code, headings, lists,
/// quotes, rules and paragraphs, with bold/italic/code/link inlines. It is
/// tolerant of half-written input, because replies are parsed while they
/// stream (an unclosed code fence is still a code block).
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

final _fence = RegExp(r'^\s*(```|~~~)\s*([\w+#.-]*)\s*$');
final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');

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

enum InlineStyle { plain, bold, italic, boldItalic, code, link }

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

final _inline = RegExp(
  r'(`[^`]+`)|(\*\*\*[^*]+\*\*\*)|(\*\*[^*]+\*\*|__[^_]+__)|(\*[^*\s][^*]*\*|_[^_\s][^_]*_)|(\[[^\]]+\]\([^)]+\))',
);

List<MdSpan> parseInline(String text) {
  final spans = <MdSpan>[];
  var last = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > last) {
      spans.add(MdSpan(text.substring(last, m.start), InlineStyle.plain));
    }
    final t = m.group(0)!;
    if (m.group(1) != null) {
      spans.add(MdSpan(t.substring(1, t.length - 1), InlineStyle.code));
    } else if (m.group(2) != null) {
      spans.add(MdSpan(t.substring(3, t.length - 3), InlineStyle.boldItalic));
    } else if (m.group(3) != null) {
      spans.add(MdSpan(t.substring(2, t.length - 2), InlineStyle.bold));
    } else if (m.group(4) != null) {
      spans.add(MdSpan(t.substring(1, t.length - 1), InlineStyle.italic));
    } else {
      spans.add(MdSpan(t.substring(1, t.indexOf(']')), InlineStyle.link));
    }
    last = m.end;
  }
  if (last < text.length) {
    spans.add(MdSpan(text.substring(last), InlineStyle.plain));
  }
  return spans;
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
        MdCode(:final code) => code,
        MdRule() => '',
      },
  ];
  return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
