import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/native.dart';
import '../memory/recall_index.dart';
import 'chat_models.dart';

/// Finds messages by meaning (see RecallIndex.search).
typedef MessageSearch = Future<List<SearchHit>> Function(String query);

/// The conversation list: paged from the encrypted store, newest first with
/// pinned chats on top, plus search: title word prefixes always, and message
/// text by meaning when the embedding model is on the phone.
class ChatStore extends ChangeNotifier {
  ChatStore(this._native, {required MessageSearch searchMessages})
    : _searchMessages = searchMessages;

  final MessageSearch _searchMessages;

  static const int pageSize = 40;

  final NativeBridge _native;
  final List<ConversationInfo> _items = [];
  bool _hasMore = true;
  bool _loading = false;
  bool loaded = false;

  String _query = '';
  List<ConversationInfo>? _results;
  Timer? _debounce;

  /// While searching: the matching message of each chat found by its
  /// messages rather than its title.
  Map<String, String> snippets = const {};

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
      snippets = const {};
      notifyListeners();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      final q = _query;
      final rows = await _native.dbSearch(q, 50);
      if (q != _query) return;
      final byTitle = rows.map(ConversationInfo.fromMap).toList();
      _results = byTitle;
      snippets = const {};
      notifyListeners();
      // Message matches need the embedding model and arrive after titles.
      final hits = await _searchMessages(q);
      if (q != _query || hits.isEmpty) return;
      final found = <ConversationInfo>[];
      final found2 = <String, String>{};
      for (final h in hits) {
        if (byTitle.any((c) => c.id == h.convId)) continue;
        final row = await _native.dbConversation(h.convId);
        if (row == null) continue;
        found.add(ConversationInfo.fromMap(row));
        found2[h.convId] = h.snippet;
      }
      if (q != _query) return;
      _results = [...byTitle, ...found];
      snippets = found2;
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
