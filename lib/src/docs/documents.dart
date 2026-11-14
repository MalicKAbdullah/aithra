import '../platform/native.dart';

/// A document stored in the chat database (DocumentStore.kt): picked or
/// shared, then sent with a message.
class DocInfo {
  const DocInfo({
    required this.id,
    required this.name,
    required this.mime,
    required this.pages,
    required this.paged,
    required this.chars,
    this.convId,
    this.msgId,
    this.summary,
    this.summaryParts,
    this.unreadPages = 0,
    this.unreadablePages = 0,
  });

  factory DocInfo.fromMap(Map<String, Object?> m) => DocInfo(
    id: m['id']! as String,
    convId: m['convId'] as String?,
    msgId: m['msgId'] as int?,
    name: m['name']! as String,
    mime: m['mime']! as String,
    pages: m['pages']! as int,
    paged: m['paged']! as bool,
    chars: m['chars']! as int,
    summary: m['summary'] as String?,
    summaryParts: m['summaryParts'] as String?,
    unreadPages: m['unreadPages']! as int,
    unreadablePages: m['unreadablePages']! as int,
  );

  final String id;
  final String? convId;

  /// The message that sent it; null while it waits in the composer.
  final int? msgId;
  final String name;
  final String mime;
  final int pages;

  /// Whether [pages] are real pages (PDF); text and Word files are one.
  final bool paged;
  final int chars;
  final String? summary;

  /// A summary in progress (see DocSummarizer), kept so it can resume.
  final String? summaryParts;

  /// Scanned pages the vision model has yet to read.
  final int unreadPages;

  /// Scanned pages beyond what Aithra reads, or with nothing to read.
  final int unreadablePages;

  /// This document once sent in [convId] with message [msgId].
  DocInfo sentIn(String convId, int msgId) => DocInfo(
    id: id,
    convId: convId,
    msgId: msgId,
    name: name,
    mime: mime,
    pages: pages,
    paged: paged,
    chars: chars,
    summary: summary,
    summaryParts: summaryParts,
    unreadPages: unreadPages,
    unreadablePages: unreadablePages,
  );

  String get kind => switch (mime) {
    'application/pdf' => 'PDF',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
      'Word',
    _ => 'Text',
  };

  /// "PDF · 12 pages", "Word · 3,400 characters".
  String get detail => paged
      ? '$kind · $pages ${pages == 1 ? 'page' : 'pages'}'
      : '$kind · ${_thousands(chars)} characters';
}

String _thousands(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// A passage of a document, as retrieved for a prompt or cited under a
/// reply.
class Passage {
  const Passage({
    required this.docId,
    required this.ord,
    required this.page,
    required this.text,
  });

  factory Passage.fromMap(Map<String, Object?> m) => Passage(
    docId: m['docId']! as String,
    ord: m['ord']! as int,
    page: m['page']! as int,
    text: m['text']! as String,
  );

  final String docId;
  final int ord;

  /// 1-based PDF page; 0 for documents without pages.
  final int page;
  final String text;
}

/// One entry of the "Sources" row under a reply.
class Source {
  const Source({
    required this.docId,
    required this.ord,
    required this.page,
    required this.name,
  });

  factory Source.fromMap(Map<String, Object?> m) => Source(
    docId: m['docId']! as String,
    ord: m['ord']! as int,
    page: m['page']! as int,
    name: m['name']! as String,
  );

  final String docId;
  final int ord;
  final int page;
  final String name;

  /// "p.3", or the passage number for a document without pages.
  String get label => page > 0 ? 'p.$page' : 'part ${ord + 1}';
}

/// The heading a passage carries in the prompt: "[report.pdf · p.3]".
String passageHeader(String name, int page) =>
    page > 0 ? '[$name · p.$page]' : '[$name]';

/// What the newest user message carries from the chat's documents.
class DocumentContext {
  const DocumentContext({
    required this.text,
    required this.tokens,
    required this.cited,
    required this.whole,
    required this.searched,
  });

  /// The block put before the user's words.
  final String text;
  final int tokens;

  /// The passages given, for the Sources row; empty when [whole].
  final List<Passage> cited;

  /// Every page fit, so the model read the documents in full.
  final bool whole;

  /// Passages were chosen by meaning; false when they are the opening
  /// passages because the embedding model is not on the phone.
  final bool searched;
}

/// The share of the context documents may take in one turn, beside the
/// system message (see systemBudget) and the reply.
int documentBudget(int contextTokens) => (contextTokens * 0.35).floor();

/// Passages considered for a question; more than ever fit, so the budget,
/// not this, decides how many are sent.
const int passageCandidates = 12;

String documentBlock(List<({String header, String text})> parts) {
  final b = StringBuffer(
    'Documents the user attached to this chat. Answer from them where '
    'they apply.\n',
  );
  for (final p in parts) {
    b
      ..writeln()
      ..writeln(p.header)
      ..writeln(p.text.trim());
  }
  return b.toString().trimRight();
}

/// [userText] after the document block, as the newest turn's text.
String withDocuments(DocumentContext? docs, String userText) =>
    docs == null ? userText : '${docs.text}\n\n---\n\n$userText';

/// Chooses what of [docs] goes into the prompt for [question] within
/// [budget] tokens: every page when they all fit, otherwise the passages
/// closest to the question (in reading order without the embedding model
/// at [embedderPath]), best first until the budget is spent. [costs]
/// measures several texts at once.
Future<DocumentContext?> readDocuments({
  required NativeBridge native,
  required List<DocInfo> docs,
  required String question,
  required int budget,
  required String? embedderPath,
  required Future<List<int>> Function(List<String> texts) costs,
}) async {
  if (docs.isEmpty || budget <= 0) return null;
  final names = {for (final d in docs) d.id: d.name};
  final pages = <({String header, String text})>[
    for (final d in docs)
      for (final p in await native.documentPages(d.id))
        (
          header: passageHeader(d.name, d.paged ? p['page']! as int : 0),
          text: p['text']! as String,
        ),
  ];
  if (pages.isEmpty) return null;
  final whole = documentBlock(pages);
  final wholeCost = (await costs([whole])).single;
  if (wholeCost <= budget) {
    return DocumentContext(
      text: whole,
      tokens: wholeCost,
      cited: const [],
      whole: true,
      searched: false,
    );
  }
  final ids = [for (final d in docs) d.id];
  final searched = embedderPath != null && question.trim().isNotEmpty;
  final rows = searched
      ? await native.searchDocuments(
          embedderPath,
          ids,
          question,
          passageCandidates,
        )
      : await native.passagesInOrder(ids, passageCandidates);
  final candidates = [for (final r in rows) Passage.fromMap(r)];
  ({String header, String text}) part(Passage p) =>
      (header: passageHeader(names[p.docId]!, p.page), text: p.text);
  final each = await costs([
    for (final p in candidates) documentBlock([part(p)]),
  ]);
  final header = (await costs([documentBlock(const [])])).single;
  final chosen = <Passage>[];
  var used = header;
  for (var i = 0; i < candidates.length; i++) {
    // Each passage's own cost includes the block's heading once more.
    final cost = each[i] - header;
    if (used + cost > budget) continue;
    chosen.add(candidates[i]);
    used += cost;
  }
  if (chosen.isEmpty) return null;
  final order = [for (final d in docs) d.id];
  chosen.sort(
    (a, b) => a.docId != b.docId
        ? order.indexOf(a.docId).compareTo(order.indexOf(b.docId))
        : a.ord.compareTo(b.ord),
  );
  final text = documentBlock([for (final p in chosen) part(p)]);
  return DocumentContext(
    text: text,
    tokens: (await costs([text])).single,
    cited: chosen,
    whole: false,
    searched: searched,
  );
}

/// The instruction that has the vision model read a scanned page.
const String readPagePrompt =
    'Write out all the text on this page exactly as it appears, in reading '
    'order, keeping headings and lists. Reply with only the text, or with '
    'nothing if the page has no text.';
