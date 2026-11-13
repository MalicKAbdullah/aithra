/// Cuts streaming reply text into sentences for TextToSpeech, so speaking
/// starts on the first complete sentence while the rest is still generating.
class SentenceSplitter {
  final StringBuffer _pending = StringBuffer();
  bool _inCode = false;

  static final _end = RegExp(r'([.!?…:;]["”’)\]]?)(\s+)|\n\s*\n');

  /// Adds streamed text; returns the sentences it completed.
  List<String> add(String chunk) {
    _pending.write(chunk);
    final out = <String>[];
    var text = _pending.toString();
    while (true) {
      final m = _end.firstMatch(text);
      if (m == null) break;
      final sentence = text.substring(0, m.end);
      text = text.substring(m.end);
      _emit(sentence, out);
    }
    _pending
      ..clear()
      ..write(text);
    return out;
  }

  /// Returns whatever is left once the reply has finished.
  List<String> flush() {
    final out = <String>[];
    _emit(_pending.toString(), out);
    _pending.clear();
    return out;
  }

  void _emit(String raw, List<String> out) {
    // Code is not read aloud.
    final fences = '```'.allMatches(raw).length;
    final wasInCode = _inCode;
    if (fences.isOdd) _inCode = !_inCode;
    if (wasInCode || fences > 0) return;
    final spoken = speakable(raw);
    if (spoken.isNotEmpty) out.add(spoken);
  }
}

/// Strips Markdown syntax that would be read out literally.
String speakable(String s) => s
    .replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!)
    .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
    .replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '')
    .replaceAll(RegExp(r'[*_~>#]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
