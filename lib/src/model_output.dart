import 'dart:convert';

/// The JSON object in a model reply, or null. Model output is untrusted:
/// small models wrap JSON in prose or code fences, stop mid-object when
/// their token cap is hit, or answer something else entirely, so anything
/// that is not one well-formed object is rejected.
Map<String, Object?>? jsonObjectIn(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final v = jsonDecode(raw.substring(start, end + 1));
    return v is Map<String, Object?> ? v : null;
  } on FormatException {
    return null;
  }
}

/// [s] on one line with runs of whitespace collapsed; null when it holds
/// control characters other than whitespace.
String? oneLine(String s) {
  if (RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]').hasMatch(s)) {
    return null;
  }
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// [s] cut to at most [max] characters.
String clipChars(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max).trimRight()}…';
