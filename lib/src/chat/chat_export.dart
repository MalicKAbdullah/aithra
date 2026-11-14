import 'chat_models.dart';
import 'markdown.dart';

/// A chat as one Markdown document: the title, then each message under who
/// wrote it and when, in its own Markdown as stored.
String chatMarkdown(String title, List<ChatMessage> messages) {
  final b = StringBuffer()..writeln('# $title');
  for (final m in messages) {
    b
      ..writeln()
      ..writeln('### ${_who(m)} · ${_when(m.created)}')
      ..writeln();
    if (m.imageIds.isNotEmpty) {
      b.writeln(
        '*(${m.imageIds.length} photo${m.imageIds.length == 1 ? '' : 's'})*',
      );
    }
    if (m.content.isNotEmpty) b.writeln(m.content.trim());
  }
  return b.toString();
}

/// A chat as the entries ChatExport.pdf draws: each message's Markdown
/// reduced to blocks of plain text with a kind (`heading`, `text`, `item`,
/// `quote`, `code`, `rule`), since a PDF page has no Markdown renderer.
List<Map<String, Object?>> chatPdfEntries(List<ChatMessage> messages) => [
  for (final m in messages)
    {
      'role': m.role == Role.user ? 'user' : 'model',
      'created': m.created.millisecondsSinceEpoch,
      'blocks': [
        if (m.imageIds.isNotEmpty)
          {
            'kind': 'quote',
            'text':
                '${m.imageIds.length} photo${m.imageIds.length == 1 ? '' : 's'}',
          },
        for (final block in parseMarkdown(m.content)) _pdfBlock(block),
      ],
    },
];

Map<String, Object?> _pdfBlock(MdBlock block) => switch (block) {
  MdHeading(:final text) => {'kind': 'heading', 'text': _plain(text)},
  MdParagraph(:final text) => {'kind': 'text', 'text': _plain(text)},
  MdListItem(:final marker, :final text, :final indent) => {
    'kind': 'item',
    'text': '${'    ' * indent}$marker  ${_plain(text)}',
  },
  MdQuote(:final text) => {'kind': 'quote', 'text': _plain(text)},
  MdCode(:final code) => {'kind': 'code', 'text': code},
  MdMath(:final tex) => {'kind': 'code', 'text': tex},
  MdTable() => {'kind': 'code', 'text': tableTsv(block)},
  MdRule() => {'kind': 'rule', 'text': ''},
};

String _plain(String inline) => parseInline(inline).map((s) => s.text).join();

String _who(ChatMessage m) => m.role == Role.user ? 'You' : 'Aithra';

String _when(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

String _two(int v) => v.toString().padLeft(2, '0');
