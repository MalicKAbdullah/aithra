import 'package:aithra/src/chat/markdown.dart';
import 'package:flutter_test/flutter_test.dart';

const _plain = InlineStyle.plain;

void main() {
  group('emphasis follows CommonMark flanking rules', () {
    test('underscores inside words stay literal', () {
      expect(parseInline('use snake_case_names here'), const [
        MdSpan('use snake_case_names here', _plain),
      ]);
    });

    test('dunder names stay literal', () {
      expect(parseInline('call __init__ and self.__name__()'), const [
        MdSpan('call __init__ and self.__name__()', _plain),
      ]);
    });

    test('single underscores still italicise words', () {
      expect(parseInline('an _important_ point'), const [
        MdSpan('an ', _plain),
        MdSpan('important', InlineStyle.italic),
        MdSpan(' point', _plain),
      ]);
    });

    test('asterisks need a flanking run on each side', () {
      expect(parseInline('a * b * c'), const [MdSpan('a * b * c', _plain)]);
      expect(parseInline('2*3*4'), const [
        MdSpan('2', _plain),
        MdSpan('3', InlineStyle.italic),
        MdSpan('4', _plain),
      ]);
    });

    test('nested bold and italic', () {
      expect(parseInline('***a** b*'), const [
        MdSpan('a', InlineStyle.boldItalic),
        MdSpan(' b', InlineStyle.italic),
      ]);
      expect(parseInline('**bold *both* bold**'), const [
        MdSpan('bold ', InlineStyle.bold),
        MdSpan('both', InlineStyle.boldItalic),
        MdSpan(' bold', InlineStyle.bold),
      ]);
    });

    test('unmatched delimiters print as written', () {
      expect(parseInline('**open and never closed'), const [
        MdSpan('**open and never closed', _plain),
      ]);
    });

    test('strikethrough needs two tildes', () {
      expect(parseInline('~~gone~~ and ~5 left'), const [
        MdSpan('gone', _plain, strike: true),
        MdSpan(' and ~5 left', _plain),
      ]);
    });

    test('backslash escapes make punctuation literal', () {
      expect(parseInline(r'\*not italic\* and 3 \_ 4'), const [
        MdSpan('*not italic* and 3 _ 4', _plain),
      ]);
    });
  });

  group('links', () {
    test('keep their URL', () {
      expect(parseInline('see [the docs](https://x.dev/a_(b)) now'), const [
        MdSpan('see ', _plain),
        MdSpan('the docs', InlineStyle.link, url: 'https://x.dev/a_(b)'),
        MdSpan(' now', _plain),
      ]);
    });

    test('bare and angle URLs are links without trailing punctuation', () {
      expect(parseInline('Go to https://example.com/x.'), const [
        MdSpan('Go to ', _plain),
        MdSpan(
          'https://example.com/x',
          InlineStyle.link,
          url: 'https://example.com/x',
        ),
        MdSpan('.', _plain),
      ]);
      expect(parseInline('<https://a.b>')[0].url, 'https://a.b');
    });

    test('code in a label stays code', () {
      expect(parseInline('[`run`](http://r)'), const [
        MdSpan('run', InlineStyle.code, url: 'http://r'),
      ]);
    });

    test('brackets that are not links stay text', () {
      expect(parseInline('array[0] and [x]'), const [
        MdSpan('array[0] and [x]', _plain),
      ]);
    });
  });

  group('code spans', () {
    test('longer fences hold backticks', () {
      expect(parseInline('``a ` b``'), const [
        MdSpan('a ` b', InlineStyle.code),
      ]);
    });
  });

  group('fences', () {
    test('info strings with attributes give the language', () {
      final b = parseMarkdown('```python title="x.py"\nprint(1)\n```\nafter');
      expect((b[0] as MdCode).language, 'python');
      expect((b[0] as MdCode).closed, isTrue);
      expect((b[1] as MdParagraph).text, 'after');
      expect(
        (parseMarkdown('```{.rust}\nfn\n```')[0] as MdCode).language,
        'rust',
      );
    });

    test('four-backtick fences hold triple backticks', () {
      final b = parseMarkdown('````md\n```js\nx\n```\n````\ntail');
      expect((b[0] as MdCode).code, '```js\nx\n```');
      expect((b[1] as MdParagraph).text, 'tail');
    });

    test('code fenced inside a list item loses the item indent', () {
      final b = parseMarkdown('1. Run:\n   ```sh\n   ls -la\n     x\n   ```');
      expect((b[1] as MdCode).code, 'ls -la\n  x');
    });

    test('one-line triple backticks are inline code', () {
      expect(parseMarkdown('```x```').single, isA<MdParagraph>());
    });
  });

  group('blocks', () {
    test('list items continue over lines', () {
      final b = parseMarkdown('- first\n  more of it\n- second\n\nafter');
      expect((b[0] as MdListItem).text, 'first\nmore of it');
      expect((b[1] as MdListItem).text, 'second');
      expect(b[2], isA<MdParagraph>());
    });

    test('task items', () {
      final b = parseMarkdown('- [ ] todo\n- [x] done');
      expect((b[0] as MdListItem).checked, isFalse);
      expect((b[0] as MdListItem).text, 'todo');
      expect((b[1] as MdListItem).checked, isTrue);
    });

    test('a quote is one block over its lines and holds Markdown', () {
      final b = parseMarkdown('> line one\n> line two\n>\n> - item');
      final q = b.single as MdQuote;
      expect(q.blocks[0], isA<MdParagraph>());
      expect((q.blocks[0] as MdParagraph).text, 'line one\nline two');
      expect(q.blocks[1], isA<MdListItem>());
    });

    test('headings drop closing hashes; hashtags are text', () {
      expect((parseMarkdown('## Title ##').single as MdHeading).text, 'Title');
      expect(parseMarkdown('#hashtag').single, isA<MdParagraph>());
    });

    test('tables', () {
      final b = parseMarkdown(
        'Intro\n| Name | Qty |\n|:-----|----:|\n| a `x|y` | 1 |\n| b | 2 | 9 |\n| c |\n\nafter',
      );
      expect((b[0] as MdParagraph).text, 'Intro');
      final t = b[1] as MdTable;
      expect(t.header, ['Name', 'Qty']);
      expect(t.align, [MdAlign.start, MdAlign.end]);
      expect(t.rows, [
        ['a `x|y`', '1'],
        ['b', '2'],
        ['c', ''],
      ]);
      expect(b[2], isA<MdParagraph>());
    });

    test('a header row without its delimiter is text', () {
      expect(parseMarkdown('| a | b |').single, isA<MdParagraph>());
    });
  });

  group('text forms', () {
    const source =
        '# Plan\n\nBuy **milk** from [the shop](https://shop.example).\n\n'
        '- eggs\n- bread\n\n1. one\n2. two\n\n```py\nprint(1)\n```\n\n'
        '| A | B |\n|---|---|\n| 1 | 2 |\n\n\$\$\nx^2\n\$\$';

    test('plain text', () {
      expect(
        plainText(source),
        'Plan\n\nBuy milk from the shop (https://shop.example).\n\n'
        '• eggs\n• bread\n\n1. one\n2. two\n\nprint(1)\n\nA\tB\n1\t2\n\nx^2',
      );
    });

    test('html', () {
      final html = markdownHtml(source);
      expect(html, contains('<h1>Plan</h1>'));
      expect(html, contains('<strong>milk</strong>'));
      expect(html, contains('<a href="https://shop.example">the shop</a>'));
      expect(html, contains('<ul><li>eggs</li><li>bread</li></ul>'));
      expect(html, contains('<ol><li>one</li><li>two</li></ol>'));
      expect(html, contains('<pre><code>print(1)</code></pre>'));
      expect(html, contains('<th>A</th>'));
      expect(markdownHtml('a < b & c'), '<p>a &lt; b &amp; c</p>');
    });

    test('nested lists in html', () {
      expect(
        markdownHtml('- a\n  - b\n- c'),
        '<ul><li>a</li><ul><li>b</li></ul><li>c</li></ul>',
      );
    });
  });

  test('pathological input parses in linear-ish time', () {
    final inputs = [
      '*' * 20000,
      '_a' * 10000,
      '[' * 20000,
      '`' * 20000,
      '\$' * 20000,
      '*a ' * 7000,
      '**a' * 7000,
      '~~' * 10000,
      '| a ' * 5000,
    ];
    final watch = Stopwatch()..start();
    for (final s in inputs) {
      parseMarkdown(s);
      parseInline(s);
    }
    expect(watch.elapsedMilliseconds, lessThan(3000));
  });
}
