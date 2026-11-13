import 'package:flutter/foundation.dart';

import '../data/vault.dart';

class Memory {
  const Memory({required this.id, required this.text, required this.created});

  factory Memory.fromJson(Map<String, Object?> j) => Memory(
    id: j['id']! as String,
    text: j['text']! as String,
    created: DateTime.fromMillisecondsSinceEpoch(j['created']! as int),
  );

  final String id;
  final String text;
  final DateTime created;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'created': created.millisecondsSinceEpoch,
  };
}

/// What Aithra remembers about the user, newest first, encrypted on this
/// phone. The model adds, updates and retires memories itself after replies
/// (see MemoryKeeper); the user can view, edit and delete them, and every
/// chat's system prompt includes them while memory is on.
class MemoryStore extends ChangeNotifier {
  MemoryStore(this._vault);

  final Vault _vault;
  List<Memory> _items = [];

  List<Memory> get items => List.unmodifiable(_items);

  Future<void> load() async {
    final j = await _vault.read('memories') as List?;
    _items = [
      for (final m in j ?? const [])
        Memory.fromJson(Map<String, Object?>.from(m as Map)),
    ];
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    await _vault.write('memories', [for (final m in _items) m.toJson()]);
  }

  bool knows(String text) =>
      _items.any((m) => m.text.toLowerCase() == text.trim().toLowerCase());

  /// Adds [text] unless it is blank or already remembered; returns whether
  /// it was added.
  Future<bool> add(String text) async {
    final t = text.trim();
    if (t.isEmpty || knows(t)) return false;
    _items.insert(
      0,
      Memory(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        text: t,
        created: DateTime.now(),
      ),
    );
    await _save();
    return true;
  }

  /// Rewrites memory [id]; returns whether it exists and changed.
  Future<bool> edit(String id, String text) async {
    final t = text.trim();
    final i = _items.indexWhere((m) => m.id == id);
    if (i < 0 || t.isEmpty || _items[i].text == t) return false;
    final m = _items[i];
    _items = [..._items]..[i] = Memory(id: m.id, text: t, created: m.created);
    await _save();
    return true;
  }

  /// Removes the memory and returns it with its position, for [restore].
  Future<(Memory, int)?> remove(String id) async {
    final i = _items.indexWhere((m) => m.id == id);
    if (i < 0) return null;
    final m = _items.removeAt(i);
    await _save();
    return (m, i);
  }

  /// Puts back a memory taken out by [remove], where it was.
  Future<void> restore(Memory memory, int index) {
    if (_items.any((m) => m.id == memory.id)) return Future.value();
    _items.insert(index.clamp(0, _items.length), memory);
    return _save();
  }
}
