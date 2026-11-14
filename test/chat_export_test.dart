import 'package:aithra/src/chat/chat_export.dart';
import 'package:aithra/src/chat/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage msg(int seq, Role role, String content, {List<String>? images}) =>
    ChatMessage(
      id: seq,
      seq: seq,
      role: role,
      content: content,
      imageIds: images ?? const [],
      created: DateTime(2026, 11, 15, 9, 5 + seq),
    );

void main() {
  final chat = [
    msg(0, Role.user, 'What is in this photo?', images: ['a']),
    msg(
      1,
      Role.model,
      '## A harbour\n\nIt shows **boats**.\n\n- a ferry\n2. a tug\n\n'
      '```\nlet x = 1;\n```\n\n> calm water\n\n---',
    ),
  ];

  test('Markdown keeps each message as written under who and when', () {
    final md = chatMarkdown('Harbour', chat);
    expect(md, startsWith('# Harbour\n'));
    expect(md, contains('### You · 2026-11-15 09:05\n\n*(1 photo)*\n'));
    expect(md, contains('### Aithra · 2026-11-15 09:06\n\n## A harbour'));
    expect(md, contains('It shows **boats**.'));
  });

  test('PDF entries reduce Markdown to plain blocks by kind', () {
    final entries = chatPdfEntries(chat);
    expect(entries.first['role'], 'user');
    expect(entries.first['blocks'], [
      {'kind': 'quote', 'text': '1 photo'},
      {'kind': 'text', 'text': 'What is in this photo?'},
    ]);
    final blocks = entries.last['blocks']! as List;
    expect(blocks, [
      {'kind': 'heading', 'text': 'A harbour'},
      {'kind': 'text', 'text': 'It shows boats.'},
      {'kind': 'item', 'text': '•  a ferry'},
      {'kind': 'item', 'text': '2.  a tug'},
      {'kind': 'code', 'text': 'let x = 1;'},
      {'kind': 'quote', 'text': 'calm water'},
      {'kind': 'rule', 'text': ''},
    ]);
  });
}
