import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_models.dart';
import '../chat/chat_sessions.dart';
import '../chat/chat_store.dart';
import '../docs/documents.dart';
import '../platform/native.dart';
import 'shared_item.dart';

/// Shared text up to this length goes into the composer; longer text is
/// attached as a document, which the composer would not hold well.
const int composerTextLimit = 4000;

/// Takes what MainActivity received for the app: a share from another app
/// opens a new chat holding it, a chat continued from the Ask sheet opens
/// that chat. Read once when the app starts and again on every `inbox`
/// event.
class Inbox {
  Inbox({
    required NativeBridge native,
    required ChatSessions sessions,
    required ChatStore store,
    required GlobalKey<NavigatorState> navigator,
    required GlobalKey<ScaffoldMessengerState> messenger,
  }) : _native = native,
       _sessions = sessions,
       _store = store,
       _navigator = navigator,
       _messenger = messenger;

  final NativeBridge _native;
  final ChatSessions _sessions;
  final ChatStore _store;
  final GlobalKey<NavigatorState> _navigator;
  final GlobalKey<ScaffoldMessengerState> _messenger;
  StreamSubscription<Object?>? _events;

  void start() {
    _events ??= _native.eventsOf('inbox').listen((_) => _take());
    unawaited(_take());
  }

  Future<void> _take() async {
    final m = await _native.takeInbox();
    if (m == null) return;
    _navigator.currentState?.popUntil((r) => r.isFirst);
    switch (m['kind']) {
      case 'chat':
        // Without an id the Ask sheet only opened the app.
        final id = m['id'] as String?;
        if (id == null) return;
        await _store.upsert(id);
        final row = await _native.dbConversation(id);
        if (row != null) _sessions.open(ConversationInfo.fromMap(row));
      case 'share':
        await _share(m);
    }
  }

  Future<void> _share(Map<String, Object?> m) async {
    final failures = [for (final f in m['failures']! as List) f as String];
    final docs = <DocInfo>[];
    for (final f in m['files']! as List) {
      final file = Map<String, Object?>.from(f! as Map);
      try {
        docs.add(
          DocInfo.fromMap(
            await _native.importSharedFile(
              path: file['path']! as String,
              name: file['name']! as String,
              mime: file['mime'] as String?,
            ),
          ),
        );
      } on PlatformException catch (e) {
        failures.add(e.message ?? e.code);
      }
    }
    final text = [
      m['subject'] as String?,
      m['text'] as String?,
    ].nonNulls.where((t) => t.trim().isNotEmpty).toSet().join('\n\n');
    final long = text.length > composerTextLimit;
    if (long) {
      final name = (m['subject'] as String?)?.trim();
      docs.add(
        DocInfo.fromMap(
          await _native.importTextDocument(
            name == null || name.isEmpty ? 'Shared text' : name,
            text,
          ),
        ),
      );
    }
    final item = SharedItem(
      text: long ? '' : text,
      images: [for (final i in m['images']! as List) i! as Uint8List],
      documents: docs,
    );
    if (item.text.isNotEmpty || item.images.isNotEmpty || docs.isNotEmpty) {
      _sessions.startNew();
      _sessions.current.incoming.value = item;
    }
    if (failures.isNotEmpty) {
      _messenger.currentState?.showSnackBar(
        SnackBar(content: Text("Couldn't add: ${failures.join(' · ')}")),
      );
    }
  }
}
