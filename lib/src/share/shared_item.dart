import 'dart:typed_data';

import '../docs/documents.dart';

/// What another app shared into a new chat: it fills the composer, with the
/// chips that fit it, and waits for the user to send.
class SharedItem {
  const SharedItem({
    this.text = '',
    this.images = const [],
    this.documents = const [],
  });

  /// Shared text short enough to sit in the composer; longer text arrives
  /// as a document.
  final String text;
  final List<Uint8List> images;
  final List<DocInfo> documents;
}
