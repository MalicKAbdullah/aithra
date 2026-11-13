import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/native.dart';
import '../memory/recall_index.dart';
import 'chat_models.dart';

/// Finds messages by meaning (see RecallIndex.search).
typedef MessageSearch = Future<List<SearchHit>> Function(String query);

/// The conversation list: paged from the encrypted store, newest first with
/// pinned chats on top, plus search: title word prefixes and message text
/// always, and messages by meaning when the embedding model is on the
/// phone.
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
      final (titles, texts) = await (
        _native.dbSearch(q, 50),
        _native.dbSearchText(q, 50),
      ).wait;
      if (q != _query) return;
      final found = titles.map(ConversationInfo.fromMap).toList();
      final matched = <String, String>{};
      for (final row in texts) {
        final info = ConversationInfo.fromMap(row);
        if (found.any((c) => c.id == info.id)) continue;
        found.add(info);
        matched[info.id] = row['snippet']! as String;
      }
      _results = found;
      snippets = matched;
      notifyListeners();
      // Matches by meaning need the embedding model and arrive last.
      final hits = await _searchMessages(q);
      if (q != _query || hits.isEmpty) return;
      final byMeaning = <ConversationInfo>[];
      final meaningSnippets = <String, String>{};
      for (final h in hits) {
        if (found.any((c) => c.id == h.convId)) continue;
        final row = await _native.dbConversation(h.convId);
        if (row == null) continue;
        byMeaning.add(ConversationInfo.fromMap(row));
        meaningSnippets[h.convId] = h.snippet;
      }
      if (q != _query || byMeaning.isEmpty) return;
      _results = [...found, ...byMeaning];
      snippets = {...matched, ...meaningSnippets};
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
