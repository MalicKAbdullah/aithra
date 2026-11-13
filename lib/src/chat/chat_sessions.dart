import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_models.dart';
import 'chat_session.dart';
import 'chat_store.dart';

/// The chats the app holds open: the one on screen ([current]) and every
/// other one whose reply is still generating or waiting its turn. It lives
/// as long as the app, so a reply keeps going, and is saved to its own chat,
/// while the user opens the drawer, reads another chat or starts a new one;
/// coming back finds the same session, still streaming or finished. A chat
/// that is neither on screen nor replying is let go.
class ChatSessions extends ChangeNotifier {
  ChatSessions({
    required ChatSession Function(ConversationInfo? conversation) create,
    required ChatStore store,
  }) : _create = create,
       _store = store {
    _current = _adopt(_create(null));
  }

  final ChatSession Function(ConversationInfo?) _create;
  final ChatStore _store;
  final List<ChatSession> _live = [];
  late ChatSession _current;

  /// Conversations whose reply runs or waits, as last announced.
  Set<String> _replying = const {};
  Set<String> _queued = const {};

  /// The chat on screen.
  ChatSession get current => _current;

  /// Whether [convId]'s reply is generating or waiting for the engine.
  bool replying(String convId) => _replying.contains(convId);

  /// Whether [convId]'s reply waits for another chat's reply to finish.
  bool queued(String convId) => _queued.contains(convId);

  /// Shows [info]'s chat: the session still held for it when its reply
  /// runs, otherwise a fresh one read from the store.
  void open(ConversationInfo info) {
    if (_current.conversation?.id == info.id) return;
    final live = _live.where((s) => s.conversation?.id == info.id).firstOrNull;
    _show(live ?? _adopt(_create(info)));
  }

  /// Shows a new, empty chat. Nothing is stored until its first message, so
  /// the screen already showing an untouched new chat keeps it.
  void startNew() {
    if (_current.conversation == null && !_current.busy) return;
    _show(_adopt(_create(null)));
  }

  /// Deletes a chat. Its reply is stopped and allowed to finish saving
  /// first, so nothing is written to the chat after it is gone; deleting the
  /// chat on screen shows a new one.
  Future<void> delete(String convId) async {
    final live = _live.where((s) => s.conversation?.id == convId).firstOrNull;
    if (live != null) {
      _live.remove(live);
      if (identical(live, _current)) _show(_adopt(_create(null)));
      _announce();
      await live.stop();
      await live.settled;
      live.dispose();
    }
    await _store.delete(convId);
  }

  /// A session made outside the screen's flow (voice mode), sharing the
  /// reply queue; its owner disposes it.
  ChatSession detached() => _create(null);

  void _show(ChatSession next) {
    final previous = _current;
    _current = next;
    _announce(force: true);
    if (!previous.busy) _let(previous);
  }

  ChatSession _adopt(ChatSession s) {
    _live.add(s);
    s.addListener(() => _changed(s));
    return s;
  }

  void _changed(ChatSession s) {
    _announce();
    if (!s.busy && !identical(s, _current)) _let(s);
  }

  /// Releases a session that is off screen and idle. Disposal waits a
  /// microtask, since this can run inside the session's own notification.
  void _let(ChatSession s) {
    if (!_live.remove(s)) return;
    // Its conversation moved in the list (new title, latest message) while
    // it was away from the screen.
    final id = s.conversation?.id;
    if (id != null) unawaited(_store.upsert(id));
    scheduleMicrotask(s.dispose);
  }

  void _announce({bool force = false}) {
    final replying = {
      for (final s in _live)
        if (s.busy && s.conversation != null) s.conversation!.id,
    };
    final queued = {
      for (final s in _live)
        if (s.phase == ReplyPhase.queued && s.conversation != null)
          s.conversation!.id,
    };
    if (!force &&
        setEquals(replying, _replying) &&
        setEquals(queued, _queued)) {
      return;
    }
    _replying = replying;
    _queued = queued;
    notifyListeners();
  }
}
