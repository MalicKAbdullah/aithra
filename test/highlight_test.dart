import 'package:aithra/src/chat/highlight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String kinds(List<CodeToken> t) => t
      .where((x) => x.kind != TokenKind.plain)
      .map((x) => '${x.kind.name}:${x.text}')
      .join(' ');

  test('python keywords, strings, numbers and comments', () {
    final t = highlight('def f(x):\n    return "a#b" + 2  # done', 'python');
    expect(
      kinds(t),
      'keyword:def keyword:return string:"a#b" number:2 comment:# done',
    );
    expect(
      t.map((x) => x.text).join(),
      'def f(x):\n    return "a#b" + 2  # done',
    );
  });

  test('C-like comments; # is not a comment in JavaScript', () {
    expect(
      kinds(highlight('const a = 1; // one\n/* two */ let b = "#x";', 'js')),
      'keyword:const number:1 comment:// one comment:/* two */ keyword:let string:"#x"',
    );
  });

  test('an unclosed string while streaming runs to the end of the line', () {
    expect(kinds(highlight('print("hal', 'python')), 'string:"hal');
  });

  test('identifiers containing digits are not numbers', () {
    expect(kinds(highlight('x1 = y2', 'python')), '');
  });
}
