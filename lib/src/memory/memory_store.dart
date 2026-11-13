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

/// Facts the user chose to have Aithra remember, encrypted on this phone.
/// Every chat's system prompt includes them.
class MemoryStore extends ChangeNotifier {
  MemoryStore(this._vault);

  final Vault _vault;
  List<Memory> _items = [];

  /// Facts suggested in this session that the user dismissed; not offered again.
  final Set<String> _dismissed = {};

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
      _items.any((m) => m.text.toLowerCase() == text.toLowerCase());

  /// Suggestions worth showing: not already saved, not dismissed.
  List<String> filterSuggestions(List<String> candidates) => [
    for (final c in candidates)
      if (!knows(c) && !_dismissed.contains(c)) c,
  ];

  void dismiss(String suggestion) {
    _dismissed.add(suggestion);
    notifyListeners();
  }

  Future<void> add(String text) {
    final t = text.trim();
    if (t.isEmpty || knows(t)) return Future.value();
    _items.insert(
      0,
      Memory(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        text: t,
        created: DateTime.now(),
      ),
    );
    return _save();
  }

  Future<void> edit(String id, String text) {
    _items = [
      for (final m in _items)
        m.id == id
            ? Memory(id: m.id, text: text.trim(), created: m.created)
            : m,
    ];
    return _save();
  }

  Future<void> remove(String id) {
    _items.removeWhere((m) => m.id == id);
    return _save();
  }
}
