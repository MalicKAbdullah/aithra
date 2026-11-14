/// A small Markdown parser for chat replies: fenced code, display math,
/// headings, lists (with task items), quotes, tables, rules and paragraphs,
/// with bold/italic/strikethrough/code/link and LaTeX math inlines. It is
/// tolerant of half-written input, because replies are parsed while they
/// stream: an unclosed code fence is still a code block, and math whose
/// closing delimiter has not arrived yet stays plain text until it does.
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

  /// The first word of the fence's info string, without attribute syntax
  /// (`{.python}` reads as `python`).
  final String language;
  final String code;
  final bool closed;
}

class MdListItem extends MdBlock {
  const MdListItem(
    this.text, {
    required this.marker,
    required this.indent,
    this.checked,
  });

  /// "•" for bullets, "3." for numbered items.
  final String marker;
  final int indent;
  final String text;

  /// A task item's box: true when ticked; null for an ordinary item.
  final bool? checked;
}

class MdQuote extends MdBlock {
  MdQuote(this.text);

  /// The quoted Markdown with its `>` markers removed.
  final String text;

  /// A quote holds whole Markdown (paragraphs, lists, code) of its own.
  late final List<MdBlock> blocks = parseMarkdown(text);
}

class MdRule extends MdBlock {
  const MdRule();
}

/// A display equation on lines of its own: `$$ … $$` or `\[ … \]`.
class MdMath extends MdBlock {
  const MdMath(this.tex);
  final String tex;
}

enum MdAlign { start, center, end }

/// A GitHub-style pipe table. Every row has exactly as many cells as
/// [header]; cells hold inline Markdown.
class MdTable extends MdBlock {
  const MdTable(this.header, this.align, this.rows);
  final List<String> header;
  final List<MdAlign> align;
  final List<List<String>> rows;
}

final _fenceOpen = RegExp(r'^( *)(`{3,}|~{3,})(.*)$');
final _heading = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$');
final _bullet = RegExp(r'^([ \t]*)([-*+])(?:[ \t]+(.*))?$');
final _numbered = RegExp(r'^([ \t]*)(\d{1,9})[.)](?:[ \t]+(.*))?$');
final _task = RegExp(r'^\[([ xX])\](?:[ \t]+(.*))?$');
final _rule = RegExp(r'^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$');
final _quote = RegExp(r'^ {0,3}> ?(.*)$');
final _delimiterRow = RegExp(r'^ *\|? *:?-+:? *(?:\| *:?-+:? *)*\|? *$');

int _indentWidth(String ws) {
  var w = 0;
  for (final c in ws.codeUnits) {
    w += c == 0x09 ? 4 : 1;
  }
  return w;
}

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

/// The cells of a table row: split on pipes that are neither escaped nor
/// inside a code span, with the optional outer pipes dropped.
List<String> _cells(String line) {
  var s = line.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|') && !s.endsWith(r'\|')) s = s.substring(0, s.length - 1);
  final cells = <String>[];
  final cell = StringBuffer();
  var inCode = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length && s[i + 1] == '|') {
      cell.write('|');
      i++;
    } else if (c == '`') {
      inCode = !inCode;
      cell.write(c);
    } else if (c == '|' && !inCode) {
      cells.add(cell.toString().trim());
      cell.clear();
    } else {
      cell.write(c);
    }
  }
  cells.add(cell.toString().trim());
  return cells;
}

/// Whether [line] starts a block that ends the paragraph, list item or
/// table row before it.
bool _interrupts(List<String> lines, int i) {
  final line = lines[i];
  return _fenceOpen.hasMatch(line) && _fenceInfoOk(line) ||
      _heading.hasMatch(line) && _headingText(line) != null ||
      _rule.hasMatch(line) ||
      _bullet.hasMatch(line) ||
      _numbered.hasMatch(line) ||
      _quote.hasMatch(line) ||
      _displayMath(lines, i) != null;
}

/// A backtick fence's info string cannot hold a backtick, so "```x```" on
/// one line is inline code, not a fence.
bool _fenceInfoOk(String line) {
  final m = _fenceOpen.firstMatch(line)!;
  return !(m[2]!.startsWith('`') && m[3]!.contains('`'));
}

String? _headingText(String line) {
  final m = _heading.firstMatch(line);
  final text = m?[2]?.trim();
  return text == null || text.isEmpty ? null : text;
}

String _language(String info) {
  final word = info.trim().split(RegExp(r'\s+')).first;
  return word.replaceAll(RegExp(r'^[{.]+|[},]+$'), '');
}

MdTable? _table(List<String> lines, int i) {
  if (i + 1 >= lines.length) return null;
  final head = lines[i];
  final delim = lines[i + 1];
  if (!head.contains('|') || !_delimiterRow.hasMatch(delim)) return null;
  if (!delim.contains('|') && !head.trim().startsWith('|')) return null;
  final header = _cells(head);
  final marks = _cells(delim);
  if (header.length != marks.length) return null;
  final align = [
    for (final m in marks)
      m.startsWith(':') && m.endsWith(':')
          ? MdAlign.center
          : m.endsWith(':')
          ? MdAlign.end
          : MdAlign.start,
  ];
  return MdTable(header, align, const []);
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
    final fence = _fenceOpen.firstMatch(line);
    if (fence != null && _fenceInfoOk(line)) {
      flush();
      final indent = fence[1]!.length;
      final mark = fence[2]!;
      final close = RegExp('^ *${RegExp.escape(mark[0])}{${mark.length},} *\$');
      final code = <String>[];
      var closed = false;
      for (i++; i < lines.length; i++) {
        if (close.hasMatch(lines[i])) {
          closed = true;
          break;
        }
        // Code fenced inside a list item carries the item's indentation.
        final l = lines[i];
        var cut = 0;
        while (cut < indent && cut < l.length && l[cut] == ' ') {
          cut++;
        }
        code.add(l.substring(cut));
      }
      blocks.add(MdCode(_language(fence[3]!), code.join('\n'), closed: closed));
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
    final heading = _headingText(line);
    if (heading != null) {
      flush();
      blocks.add(MdHeading(_heading.firstMatch(line)![1]!.length, heading));
      continue;
    }
    if (_rule.hasMatch(line)) {
      flush();
      blocks.add(const MdRule());
      continue;
    }
    final quote = _quote.firstMatch(line);
    if (quote != null) {
      flush();
      final body = [quote[1]!];
      while (i + 1 < lines.length) {
        final next = _quote.firstMatch(lines[i + 1]);
        if (next == null) break;
        body.add(next[1]!);
        i++;
      }
      blocks.add(MdQuote(body.join('\n')));
      continue;
    }
    final b = _bullet.firstMatch(line);
    final n = b == null ? _numbered.firstMatch(line) : null;
    if (b != null || n != null) {
      flush();
      final m = (b ?? n)!;
      var text = (b != null ? b[3] : n![3]) ?? '';
      bool? checked;
      final task = _task.firstMatch(text);
      if (task != null) {
        checked = task[1] != ' ';
        text = task[2] ?? '';
      }
      final body = [text];
      // Continuation lines, indented or not, belong to the item until a
      // blank line or another block.
      while (i + 1 < lines.length &&
          lines[i + 1].trim().isNotEmpty &&
          !_interrupts(lines, i + 1) &&
          _table(lines, i + 1) == null) {
        body.add(lines[++i].trim());
      }
      blocks.add(
        MdListItem(
          body.join('\n'),
          marker: b != null ? '•' : '${n![2]}.',
          indent: _indentWidth(m[1]!) ~/ 2,
          checked: checked,
        ),
      );
      continue;
    }
    final table = _table(lines, i);
    if (table != null) {
      flush();
      final width = table.header.length;
      final rows = <List<String>>[];
      i++;
      while (i + 1 < lines.length &&
          lines[i + 1].contains('|') &&
          lines[i + 1].trim().isNotEmpty &&
          !_interrupts(lines, i + 1)) {
        final cells = _cells(lines[++i]);
        rows.add([
          for (var c = 0; c < width; c++) c < cells.length ? cells[c] : '',
        ]);
      }
      blocks.add(MdTable(table.header, table.align, rows));
      continue;
    }
    para.add(line.trimLeft());
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
  const MdSpan(this.text, this.style, {this.url, this.strike = false});
  final String text;
  final InlineStyle style;

  /// Where a [InlineStyle.link] span points.
  final String? url;
  final bool strike;

  @override
  bool operator ==(Object other) =>
      other is MdSpan &&
      other.text == text &&
      other.style == style &&
      other.url == url &&
      other.strike == strike;

  @override
  int get hashCode => Object.hash(text, style, url, strike);

  @override
  String toString() =>
      '${style.name}${strike ? '~' : ''}("$text"${url == null ? '' : ' → $url'})';
}

/// Inline Markdown in [text]. Code spans, math and links are found first,
/// so the `*`, `_` and `$` inside them keep their literal meaning there;
/// emphasis then follows CommonMark's delimiter-run rules.
List<MdSpan> parseInline(String text) => _InlineParser(text).parse();

const _backtick = 0x60;
const _backslash = 0x5C;
const _dollar = 0x24;

bool _isSpace(String c) => c.trim().isEmpty;
bool _isDigit(String c) => c.compareTo('0') >= 0 && c.compareTo('9') <= 0;

final _punctuation = RegExp(r'[\p{P}\p{S}]', unicode: true);
bool _isPunct(String c) => _punctuation.hasMatch(c);
bool _isAsciiPunct(int c) =>
    (c >= 0x21 && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= 0x5B && c <= 0x60) ||
    (c >= 0x7B && c <= 0x7E);

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

/// A piece of inline content before emphasis is resolved.
sealed class _Node {}

class _Literal extends _Node {
  _Literal(this.text);
  final String text;
}

class _Atom extends _Node {
  _Atom(this.spans);
  final List<MdSpan> spans;
}

class _Delim extends _Node {
  _Delim(this.char, this.length, {required this.open, required this.close})
    : left = length;
  final String char;
  final int length;
  final bool open;
  final bool close;

  /// Delimiters not yet used by a match; they print as literal text.
  int left;

  /// False once a matched pair encloses it: it can no longer open.
  bool active = true;
}

final _urlStart = RegExp('https?://');
final _wordOrSlash = RegExp(r'[\w/]');

class _InlineParser {
  _InlineParser(this.text);

  final String text;
  final List<_Node> nodes = [];
  final StringBuffer _literal = StringBuffer();
  Map<int, int>? _brackets;

  /// Past here no `>` follows, so no `<` can open an autolink.
  int _noAngleCloseFrom = 1 << 62;

  void _flushLiteral() {
    if (_literal.isEmpty) return;
    nodes.add(_Literal(_literal.toString()));
    _literal.clear();
  }

  void _atom(List<MdSpan> spans) {
    _flushLiteral();
    nodes.add(_Atom(spans));
  }

  String _charBefore(int i) => i <= 0 ? ' ' : text[i - 1];
  String _charAt(int i) => i >= text.length ? ' ' : text[i];

  /// Matching `]` for every `[`, found in one pass so a reply full of
  /// unmatched brackets stays linear.
  Map<int, int> get _bracketPairs => _brackets ??= () {
    final pairs = <int, int>{};
    final open = <int>[];
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == _backslash) {
        i++;
      } else if (c == 0x5B) {
        open.add(i);
      } else if (c == 0x5D && open.isNotEmpty) {
        pairs[open.removeLast()] = i;
      }
    }
    return pairs;
  }();

  List<MdSpan> parse() {
    var i = 0;
    while (i < text.length) {
      final ch = text.codeUnitAt(i);
      if (ch == _backtick) {
        var run = 1;
        while (i + run < text.length && text.codeUnitAt(i + run) == _backtick) {
          run++;
        }
        final close = _closingBackticks(i + run, run);
        if (close != null) {
          var code = text.substring(i + run, close);
          // One space padding each side lets code start or end with a
          // backtick, as in CommonMark.
          if (code.length > 2 &&
              code.startsWith(' ') &&
              code.endsWith(' ') &&
              code.trim().isNotEmpty) {
            code = code.substring(1, code.length - 1);
          }
          _atom([MdSpan(code, InlineStyle.code)]);
          i = close + run;
          continue;
        }
        _literal.write(text.substring(i, i + run));
        i += run;
        continue;
      }
      if (ch == _backslash && i + 1 < text.length) {
        final next = text[i + 1];
        if (next == '(' || next == '[') {
          final closer = next == '(' ? r'\)' : r'\]';
          final close = text.indexOf(closer, i + 2);
          final tex = close < 0 ? '' : text.substring(i + 2, close).trim();
          if (tex.isNotEmpty) {
            final style = next == '('
                ? InlineStyle.math
                : InlineStyle.displayMath;
            _atom([MdSpan(tex, style)]);
            i = close + 2;
            continue;
          }
          // `\(` and `\[` are LaTeX delimiters waiting for their closer,
          // so they keep their backslash.
          _literal.write(text.substring(i, i + 2));
          i += 2;
          continue;
        }
        final code = text.codeUnitAt(i + 1);
        if (_isAsciiPunct(code) && next != ')' && next != ']') {
          _literal.write(next);
          i += 2;
          continue;
        }
        _literal.write(r'\');
        i++;
        continue;
      }
      if (ch == _dollar) {
        final end = _mathEnd(text, i);
        if (end != null) {
          final display = text.startsWith(r'$$', i);
          final width = display ? 2 : 1;
          _atom([
            MdSpan(
              text.substring(i + width, end).trim(),
              display ? InlineStyle.displayMath : InlineStyle.math,
            ),
          ]);
          i = end + width;
          continue;
        }
        // A `$$` that does not open math is written whole, so its second
        // `$` cannot open inline math.
        final width = text.startsWith(r'$$', i) ? 2 : 1;
        _literal.write(text.substring(i, i + width));
        i += width;
        continue;
      }
      if (ch == 0x5B || (ch == 0x21 && _charAt(i + 1) == '[')) {
        final end = _link(ch == 0x21 ? i + 1 : i);
        if (end != null) {
          i = end;
          continue;
        }
      }
      if (ch == 0x3C && i < _noAngleCloseFrom) {
        final close = text.indexOf('>', i + 1);
        if (close < 0) _noAngleCloseFrom = i;
        if (close > 0) {
          final inner = text.substring(i + 1, close);
          if (inner.startsWith(_urlStart) && !inner.contains(' ')) {
            _atom([MdSpan(inner, InlineStyle.link, url: inner)]);
            i = close + 1;
            continue;
          }
        }
      }
      if (ch == 0x68 &&
          text.startsWith(_urlStart, i) &&
          !_wordOrSlash.hasMatch(_charBefore(i))) {
        final end = _bareUrlEnd(i);
        if (end > i + 8) {
          final url = text.substring(i, end);
          _atom([MdSpan(url, InlineStyle.link, url: url)]);
          i = end;
          continue;
        }
      }
      if (ch == 0x2A || ch == 0x5F || ch == 0x7E) {
        i = _delimiterRun(i);
        continue;
      }
      _literal.writeCharCode(ch);
      i++;
    }
    _flushLiteral();
    return _resolve();
  }

  int? _closingBackticks(int from, int run) {
    var at = text.indexOf('`' * run, from);
    while (at >= 0) {
      var end = at + run;
      while (end < text.length && text.codeUnitAt(end) == _backtick) {
        end++;
      }
      if (end - at == run) return at;
      at = text.indexOf('`' * run, end);
    }
    return null;
  }

  /// GitHub's autolink end: stop at whitespace or `<`, then drop trailing
  /// punctuation and a closing parenthesis the URL did not open.
  int _bareUrlEnd(int start) {
    var end = start;
    while (end < text.length && !_isSpace(text[end]) && text[end] != '<') {
      end++;
    }
    while (end > start) {
      final c = text[end - 1];
      if ('?!.,:;*_~\'"'.contains(c)) {
        end--;
      } else if (c == ')') {
        final s = text.substring(start, end);
        if (')'.allMatches(s).length > '('.allMatches(s).length) {
          end--;
        } else {
          break;
        }
      } else {
        break;
      }
    }
    return end;
  }

  /// `[label](destination "title")` starting at the `[` at [open]; returns
  /// the index after it, or null when it is not a link.
  int? _link(int open) {
    final close = _bracketPairs[open];
    if (close == null || close == open + 1) return null;
    if (_charAt(close + 1) != '(') return null;
    var j = close + 2;
    while (j < text.length && text[j] == ' ') {
      j++;
    }
    final String url;
    if (_charAt(j) == '<') {
      final end = text.indexOf('>', j + 1);
      if (end < 0) return null;
      url = text.substring(j + 1, end);
      j = end + 1;
    } else {
      final from = j;
      var depth = 0;
      // A raw `[` ends the destination too, which keeps a run of
      // unfinished links from rescanning the rest of the reply each time.
      while (j < text.length && !_isSpace(text[j]) && text[j] != '[') {
        final c = text[j];
        if (c == '(') depth++;
        if (c == ')') {
          if (depth == 0) break;
          depth--;
        }
        j++;
      }
      url = text.substring(from, j);
    }
    while (j < text.length && text[j] == ' ') {
      j++;
    }
    if (j < text.length && (text[j] == '"' || text[j] == "'")) {
      final end = text.indexOf(text[j], j + 1);
      if (end < 0) return null;
      j = end + 1;
      while (j < text.length && text[j] == ' ') {
        j++;
      }
    }
    if (_charAt(j) != ')' || j >= text.length) return null;
    final label = text.substring(open + 1, close);
    _atom([
      for (final s in parseInline(label))
        MdSpan(
          s.text,
          s.style == InlineStyle.code ? s.style : InlineStyle.link,
          url: url,
          strike: s.strike,
        ),
    ]);
    return j + 1;
  }

  int _delimiterRun(int i) {
    final c = text[i];
    var end = i;
    while (end < text.length && text[end] == c) {
      end++;
    }
    final length = end - i;
    final before = _charBefore(i);
    final after = _charAt(end);
    final leftFlanking =
        !_isSpace(after) &&
        (!_isPunct(after) || _isSpace(before) || _isPunct(before));
    final rightFlanking =
        !_isSpace(before) &&
        (!_isPunct(before) || _isSpace(after) || _isPunct(after));
    bool open;
    bool close;
    if (c == '_') {
      // Runs of two or more underscores stay literal: models write bold
      // with `**`, and doubled underscores mostly come from identifiers
      // such as `__init__`.
      final single = length == 1;
      open = single && leftFlanking && (!rightFlanking || _isPunct(before));
      close = single && rightFlanking && (!leftFlanking || _isPunct(after));
    } else if (c == '~') {
      // Only `~~` strikes through; a single tilde means "about".
      open = length == 2 && leftFlanking;
      close = length == 2 && rightFlanking;
    } else {
      open = leftFlanking;
      close = rightFlanking;
    }
    if (!open && !close) {
      _literal.write(text.substring(i, end));
    } else {
      _flushLiteral();
      nodes.add(_Delim(c, length, open: open, close: close));
    }
    return end;
  }

  List<MdSpan> _resolve() {
    final n = nodes.length;
    // Emphasis ranges as difference arrays over node indices, so resolving
    // stays linear however many matches a reply has.
    final bold = List<int>.filled(n + 1, 0);
    final italic = List<int>.filled(n + 1, 0);
    final strike = List<int>.filled(n + 1, 0);
    // Lowest opener index worth searching from, per delimiter kind, so an
    // unmatched closer is not re-searched (CommonMark's openers_bottom).
    final bottom = <String, int>{};
    for (var ci = 0; ci < n; ci++) {
      final closer = nodes[ci];
      if (closer is! _Delim || !closer.close) continue;
      while (closer.left > 0) {
        final key = '${closer.char}${closer.open}${closer.length % 3}';
        final floor = bottom[key] ?? -1;
        var oi = ci - 1;
        _Delim? opener;
        for (; oi > floor; oi--) {
          final o = nodes[oi];
          if (o is! _Delim ||
              o.char != closer.char ||
              !o.open ||
              !o.active ||
              o.left == 0) {
            continue;
          }
          // CommonMark's rule of three keeps `*a**b*` from pairing badly.
          if (closer.char == '*' &&
              (o.close || closer.open) &&
              (o.length + closer.length) % 3 == 0 &&
              !(o.length % 3 == 0 && closer.length % 3 == 0)) {
            continue;
          }
          opener = o;
          break;
        }
        if (opener == null) {
          bottom[key] = ci - 1;
          break;
        }
        final use = closer.char == '~'
            ? 2
            : (opener.left >= 2 && closer.left >= 2 ? 2 : 1);
        final target = closer.char == '~'
            ? strike
            : use == 2
            ? bold
            : italic;
        target[oi + 1]++;
        target[ci]--;
        opener.left -= use;
        closer.left -= use;
        // Delimiters between the pair can no longer match anything.
        for (var k = oi + 1; k < ci; k++) {
          final d = nodes[k];
          if (d is _Delim) d.active = false;
        }
      }
    }
    final spans = <MdSpan>[];
    var b = 0, it = 0, st = 0;
    for (var k = 0; k < n; k++) {
      b += bold[k];
      it += italic[k];
      st += strike[k];
      final node = nodes[k];
      final style = b > 0 && it > 0
          ? InlineStyle.boldItalic
          : b > 0
          ? InlineStyle.bold
          : it > 0
          ? InlineStyle.italic
          : InlineStyle.plain;
      switch (node) {
        case _Literal(:final text):
          _emit(spans, MdSpan(text, style, strike: st > 0));
        case _Delim(:final char, :final left):
          if (left > 0) {
            _emit(spans, MdSpan(char * left, style, strike: st > 0));
          }
        case _Atom(spans: final atoms):
          for (final a in atoms) {
            spans.add(
              MdSpan(a.text, a.style, url: a.url, strike: a.strike || st > 0),
            );
          }
      }
    }
    return spans;
  }

  /// Adds [s], merged into the previous span when it is styled the same.
  static void _emit(List<MdSpan> spans, MdSpan s) {
    if (s.text.isEmpty) return;
    final last = spans.isEmpty ? null : spans.last;
    if (last != null &&
        last.style == s.style &&
        last.strike == s.strike &&
        last.url == null &&
        s.url == null &&
        last.style != InlineStyle.code &&
        last.style != InlineStyle.math &&
        last.style != InlineStyle.displayMath) {
      spans.last = MdSpan(last.text + s.text, s.style, strike: s.strike);
    } else {
      spans.add(s);
    }
  }
}

// -- Text forms -------------------------------------------------------------

String _inlinePlain(String text, {bool urls = true}) {
  final b = StringBuffer();
  final spans = parseInline(text);
  for (var i = 0; i < spans.length; i++) {
    final s = spans[i];
    b.write(s.text);
    final url = s.url;
    // A link reads as "text (url)" once, after its last span.
    final endsLink =
        url != null && (i + 1 == spans.length || spans[i + 1].url != url);
    if (urls && endsLink && s.text != url) b.write(' ($url)');
  }
  return b.toString();
}

/// [source] as readable plain text, the form Copy and Share hand to other
/// apps: headings as lines, `• ` and `1. ` lists, code verbatim, links as
/// "text (url)", tables tab-separated and math as its TeX.
String plainText(String source) => _plainBlocks(parseMarkdown(source));

/// Whether [b] continues the list [a] is in: nested items do, and so do
/// siblings with the same kind of marker.
bool _sameList(MdBlock a, MdBlock b) =>
    a is MdListItem &&
    b is MdListItem &&
    (a.indent != b.indent || (a.marker == '•') == (b.marker == '•'));

String _plainBlocks(List<MdBlock> blocks) {
  final b = StringBuffer();
  MdBlock? prev;
  for (final block in blocks) {
    if (prev != null) {
      b.write(_sameList(prev, block) ? '\n' : '\n\n');
    }
    b.write(switch (block) {
      MdHeading(:final text) || MdParagraph(:final text) => _inlinePlain(text),
      MdListItem(:final text, :final marker, :final indent, :final checked) =>
        '${'  ' * indent}'
            '${switch (checked) {
              true => '☑',
              false => '☐',
              null => marker,
            }} '
            '${_inlinePlain(text).replaceAll('\n', '\n${'  ' * indent}  ')}',
      MdQuote(:final blocks) => _plainBlocks(blocks),
      MdCode(:final code) => code,
      MdMath(:final tex) => tex,
      MdTable() => tableTsv(block),
      MdRule() => '———',
    });
    prev = block;
  }
  return b.toString();
}

/// A table as tab-separated values, which spreadsheets paste as cells.
String tableTsv(MdTable t) => [
  t.header,
  ...t.rows,
].map((r) => r.map((c) => _inlinePlain(c, urls: false)).join('\t')).join('\n');

/// The text to read aloud: prose only, since code, tables and equations
/// do not survive being spoken.
String spokenText(String source) => [
  for (final b in parseMarkdown(source))
    switch (b) {
      MdHeading(:final text) ||
      MdParagraph(:final text) ||
      MdListItem(:final text) => _inlinePlain(text, urls: false),
      MdQuote(:final text) => spokenText(text),
      MdCode() || MdMath() || MdTable() || MdRule() => '',
    },
].where((s) => s.isNotEmpty).join('\n\n');

/// [source] as one line of plain text for a list preview: Markdown syntax
/// removed, code kept as its text, whitespace collapsed.
String plainPreview(String source) {
  final parts = <String>[
    for (final b in parseMarkdown(source))
      switch (b) {
        MdHeading(:final text) ||
        MdParagraph(:final text) ||
        MdListItem(:final text) => _inlinePlain(text, urls: false),
        MdQuote(:final text) => plainPreview(text),
        MdTable(:final header, :final rows) => [
          ...header,
          for (final r in rows) ...r,
        ].map((c) => _inlinePlain(c, urls: false)).join(' '),
        MdCode(:final code) || MdMath(tex: final code) => code,
        MdRule() => '',
      },
  ];
  return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _inlineHtml(String text) {
  final b = StringBuffer();
  for (final s in parseInline(text)) {
    var h = _escape(s.text).replaceAll('\n', '<br>');
    h = switch (s.style) {
      InlineStyle.plain || InlineStyle.link => h,
      InlineStyle.bold => '<strong>$h</strong>',
      InlineStyle.italic => '<em>$h</em>',
      InlineStyle.boldItalic => '<strong><em>$h</em></strong>',
      InlineStyle.code ||
      InlineStyle.math ||
      InlineStyle.displayMath => '<code>$h</code>',
    };
    if (s.strike) h = '<del>$h</del>';
    if (s.url case final url?) h = '<a href="${_escape(url)}">$h</a>';
    b.write(h);
  }
  return b.toString();
}

/// [source] as HTML, which word processors and mail apps paste with its
/// formatting.
String markdownHtml(String source) => _htmlBlocks(parseMarkdown(source));

String _htmlBlocks(List<MdBlock> blocks) {
  final b = StringBuffer();
  // Open lists as (tag, indent), innermost last.
  final lists = <(String, int)>[];
  void closeTo(int depth) {
    while (lists.length > depth) {
      b.write('</${lists.removeLast().$1}>');
    }
  }

  for (final block in blocks) {
    if (block is MdListItem) {
      final tag = block.marker == '•' ? 'ul' : 'ol';
      while (lists.isNotEmpty && lists.last.$2 > block.indent) {
        b.write('</${lists.removeLast().$1}>');
      }
      if (lists.isNotEmpty &&
          lists.last.$2 == block.indent &&
          lists.last.$1 != tag) {
        b.write('</${lists.removeLast().$1}>');
      }
      if (lists.isEmpty || lists.last.$2 < block.indent) {
        b.write('<$tag>');
        lists.add((tag, block.indent));
      }
      final box = switch (block.checked) {
        true => '☑ ',
        false => '☐ ',
        null => '',
      };
      b.write('<li>$box${_inlineHtml(block.text)}</li>');
      continue;
    }
    closeTo(0);
    b.write(switch (block) {
      MdHeading(:final level, :final text) =>
        '<h$level>${_inlineHtml(text)}</h$level>',
      MdParagraph(:final text) => '<p>${_inlineHtml(text)}</p>',
      MdQuote(:final blocks) =>
        '<blockquote>${_htmlBlocks(blocks)}</blockquote>',
      MdCode(:final code) => '<pre><code>${_escape(code)}</code></pre>',
      MdMath(:final tex) => '<p><code>${_escape(tex)}</code></p>',
      MdRule() => '<hr>',
      MdTable(:final header, :final rows) =>
        '<table><thead><tr>'
            '${header.map((c) => '<th>${_inlineHtml(c)}</th>').join()}'
            '</tr></thead><tbody>'
            '${rows.map((r) => '<tr>${r.map((c) => '<td>${_inlineHtml(c)}</td>').join()}</tr>').join()}'
            '</tbody></table>',
      MdListItem() => throw StateError('handled above'),
    });
  }
  closeTo(0);
  return b.toString();
}
