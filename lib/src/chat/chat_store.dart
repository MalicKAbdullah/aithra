import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/native.dart';
import 'chat_models.dart';

/// The conversation list: paged from the encrypted store, newest first with
/// pinned chats on top, plus search over titles and message words.
class ChatStore extends ChangeNotifier {
  ChatStore(this._native);

  static const int pageSize = 40;

  final NativeBridge _native;
  final List<ConversationInfo> _items = [];
  bool _hasMore = true;
  bool _loading = false;
  bool loaded = false;

  String _query = '';
  List<ConversationInfo>? _results;
  Timer? _debounce;

  List<ConversationInfo> get items => _results ?? _items;
  bool get searching => _query.isNotEmpty;
  bool get hasMore => _results == null && _hasMore;

  Future<void> refresh() async {
    _items.clear();
    _hasMore = true;
    await loadMore();
  }

  Future<void> loadMore() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    try {
      final rows = await _native.dbConversations(_items.length, pageSize);
      _items.addAll(rows.map(ConversationInfo.fromMap));
      _hasMore = rows.length == pageSize;
      loaded = true;
      notifyListeners();
    } finally {
      _loading = false;
    }
  }

  void search(String query) {
    _query = query.trim();
    _debounce?.cancel();
    if (_query.isEmpty) {
      _results = null;
      notifyListeners();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      final q = _query;
      final rows = await _native.dbSearch(q, 50);
      if (q != _query) return;
      _results = rows.map(ConversationInfo.fromMap).toList();
      notifyListeners();
    });
  }

  /// Re-reads one conversation after it changed and moves it into place.
  Future<void> upsert(String id) async {
    final row = await _native.dbConversation(id);
    _items.removeWhere((c) => c.id == id);
    if (row != null) {
      final info = ConversationInfo.fromMap(row);
      final at = _items.indexWhere(
        (c) =>
            (!c.pinned && info.pinned) ||
            (c.pinned == info.pinned && c.updated.isBefore(info.updated)),
      );
      _items.insert(at < 0 ? _items.length : at, info);
    }
    notifyListeners();
  }

  Future<void> rename(String id, String title) async {
    await _native.dbUpdateConversation(id, {'title': title});
    await upsert(id);
  }

  Future<void> setPinned(String id, bool pinned) async {
    await _native.dbUpdateConversation(id, {'pinned': pinned});
    await upsert(id);
  }

  Future<void> delete(String id) async {
    _items.removeWhere((c) => c.id == id);
    _results?.removeWhere((c) => c.id == id);
    notifyListeners();
    await _native.dbDeleteConversation(id);
  }
}
