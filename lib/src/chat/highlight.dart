/// A small single-pass syntax highlighter for code blocks in replies. It
/// knows comments, strings, numbers and the keywords of common languages,
/// which is enough colour to read code at a glance without a grammar per
/// language. Half-written input (an unclosed string while streaming) is
/// fine: the token simply runs to the end.
enum TokenKind { plain, keyword, string, comment, number }

class CodeToken {
  const CodeToken(this.text, this.kind);
  final String text;
  final TokenKind kind;

  @override
  bool operator ==(Object other) =>
      other is CodeToken && other.text == text && other.kind == kind;

  @override
  int get hashCode => Object.hash(text, kind);

  @override
  String toString() => '${kind.name}("$text")';
}

const _hashComment = {
  'python', 'py', 'sh', 'bash', 'shell', 'zsh', 'console', 'ruby', 'rb', //
  'yaml', 'yml', 'toml', 'r', 'perl', 'dockerfile', 'makefile', 'ini',
  'conf', 'powershell', 'ps1', 'elixir', 'nim',
};

const _dashComment = {'sql', 'lua', 'haskell', 'hs'};

const _keywords = {
  // Shared by many languages.
  'if', 'else', 'for', 'while', 'do', 'return', 'break', 'continue', //
  'switch', 'case', 'default', 'try', 'catch', 'finally', 'throw', 'new',
  'class', 'import', 'from', 'as', 'in', 'is', 'not', 'and', 'or',
  'true', 'false', 'null', 'nil', 'this', 'self', 'super', 'static',
  'const', 'final', 'var', 'let', 'void', 'async', 'await', 'yield',
  'with', 'extends', 'implements', 'interface', 'enum', 'public',
  'private', 'protected', 'abstract', 'package', 'export',
  // Python
  'def', 'elif', 'lambda', 'pass', 'raise', 'except', 'global',
  'nonlocal', 'del', 'assert', 'True', 'False', 'None',
  // JS / TS
  'function', 'typeof', 'instanceof', 'undefined', 'of',
  // C family, Rust, Go, Kotlin, Swift
  'int', 'char', 'float', 'double', 'bool', 'long', 'struct', 'fn', 'mut',
  'impl', 'pub', 'func', 'defer', 'fun', 'guard', 'unsafe', 'trait',
  // Shell
  'then', 'fi', 'done', 'esac',
  // SQL, conventionally upper case
  'SELECT', 'FROM', 'WHERE', 'INSERT', 'UPDATE', 'DELETE', 'CREATE',
  'TABLE', 'INTO', 'VALUES', 'JOIN', 'ON', 'GROUP', 'BY', 'ORDER', 'AND',
  'OR', 'NOT', 'NULL', 'AS', 'LIMIT',
};

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;

bool _isIdent(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39);

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

List<CodeToken> highlight(String code, String language) {
  final lang = language.toLowerCase();
  final known = lang.isNotEmpty;
  final hash = _hashComment.contains(lang) || !known;
  final slash = !_hashComment.contains(lang) && !_dashComment.contains(lang);
  final dash = _dashComment.contains(lang);

  final tokens = <CodeToken>[];
  final plain = StringBuffer();
  void flushPlain() {
    if (plain.isNotEmpty) {
      tokens.add(CodeToken(plain.toString(), TokenKind.plain));
      plain.clear();
    }
  }

  void add(int start, int end, TokenKind kind) {
    flushPlain();
    tokens.add(CodeToken(code.substring(start, end), kind));
  }

  int lineEnd(int from) {
    final n = code.indexOf('\n', from);
    return n < 0 ? code.length : n;
  }

  var i = 0;
  final n = code.length;
  while (i < n) {
    final c = code.codeUnitAt(i);
    final next = i + 1 < n ? code.codeUnitAt(i + 1) : 0;
    // Comments. An unknown language treats `#` as a comment only where a
    // shell or Python comment could start, so `#include` and CSS colours
    // survive.
    final hashHere =
        c == 0x23 &&
        hash &&
        (known ||
            i == 0 ||
            code.codeUnitAt(i - 1) == 0x20 ||
            code.codeUnitAt(i - 1) == 0x0A);
    if (hashHere ||
        (slash && c == 0x2F && next == 0x2F) ||
        (dash && c == 0x2D && next == 0x2D)) {
      final end = lineEnd(i);
      add(i, end, TokenKind.comment);
      i = end;
      continue;
    }
    if (slash && c == 0x2F && next == 0x2A) {
      final close = code.indexOf('*/', i + 2);
      final end = close < 0 ? n : close + 2;
      add(i, end, TokenKind.comment);
      i = end;
      continue;
    }
    // Strings: ', ", ` with backslash escapes, never across a line except
    // for backticks (template literals).
    if (c == 0x22 || c == 0x27 || c == 0x60) {
      var j = i + 1;
      while (j < n) {
        final d = code.codeUnitAt(j);
        if (d == 0x5C) {
          j += 2;
          continue;
        }
        if (d == c) {
          j++;
          break;
        }
        if (d == 0x0A && c != 0x60) break;
        j++;
      }
      if (j > n) j = n;
      add(i, j, TokenKind.string);
      i = j;
      continue;
    }
    if (_isDigit(c) && (i == 0 || !_isIdent(code.codeUnitAt(i - 1)))) {
      var j = i + 1;
      while (j < n &&
          (_isIdent(code.codeUnitAt(j)) || code.codeUnitAt(j) == 0x2E)) {
        j++;
      }
      add(i, j, TokenKind.number);
      i = j;
      continue;
    }
    if (_isIdentStart(c)) {
      var j = i + 1;
      while (j < n && _isIdent(code.codeUnitAt(j))) {
        j++;
      }
      final word = code.substring(i, j);
      if (_keywords.contains(word)) {
        add(i, j, TokenKind.keyword);
      } else {
        plain.write(word);
      }
      i = j;
      continue;
    }
    plain.writeCharCode(c);
    i++;
  }
  flushPlain();
  return tokens;
}
