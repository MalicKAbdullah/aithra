import 'package:flutter/foundation.dart';

import '../data/vault.dart';
import 'profile.dart';

/// One line a tidy-up batch keeps: the old notes it stands for and the
/// lines from earlier batches it absorbs.
typedef TidyLine = ({
  ProfileSection section,
  String text,
  List<String> notes,
  List<String> absorbs,
});

/// A tidy-up batch as validated: every old note in it is either in one
/// [keep] line or in [setAside], with the section it would go back to.
typedef TidyBatch = ({
  List<TidyLine> keep,
  List<({String note, ProfileSection section})> setAside,
});

/// What Aithra knows about the user: a profile in sections, suggestions
/// waiting for the user's word, notes set aside, and things the user asked
/// to remember that the model has not filed yet. Encrypted on this phone.
///
/// The memories kept before the profile existed stay in their own document
/// until the one-time tidy-up has sorted them and the user has either
/// confirmed or undone it; nothing is lost on the way.
class MemoryStore extends ChangeNotifier {
  MemoryStore(this._vault);

  final Vault _vault;

  static const String document = 'profile.v2';
  static const String legacyDocument = 'memories';

  /// Bumped when the tidy-up's rules change, so it runs again.
  static const int tidyVersion = 1;

  final Map<ProfileSection, List<ProfileItem>> _sections = {
    for (final s in ProfileSection.values) s: const [],
  };
  List<Suggestion> _suggested = const [];
  List<ArchivedItem> _archived = const [];
  List<PendingMemory> _pending = const [];
  List<LegacyMemory> _legacy = const [];
  TidyReport _tidy = const TidyReport();
  int? _tidied;
  bool loaded = false;

  /// Bumped by every change, so model work started on an older profile
  /// can tell it is out of date.
  int revision = 0;

  static int _seq = 0;
  static String newId() => '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  List<ProfileItem> section(ProfileSection s) => _sections[s]!;

  /// Every profile line, in section order.
  Iterable<ProfileItem> get items =>
      ProfileSection.values.expand((s) => _sections[s]!);

  int get count => items.length;

  List<Suggestion> get suggested => _suggested;
  List<ArchivedItem> get archived => _archived;
  List<PendingMemory> get pending => _pending;

  /// Old memories the tidy-up has not reached yet. Until it does they are
  /// still used in chats, after the profile.
  List<LegacyMemory> get untidied => tidying
      ? [
          for (final m in _legacy)
            if (!_tidy.processed.contains(m.id)) m,
        ]
      : const [];

  bool get tidying => _legacy.isNotEmpty && _tidied != tidyVersion;

  /// The finished tidy-up, while it waits for the user to review it.
  TidyReport? get tidyReport =>
      !tidying && _legacy.isNotEmpty && _tidy.changedAnything ? _tidy : null;

  /// Invalid model answers for the tidy-up batch now being sorted.
  int get tidyFailures => _tidy.failures;

  /// Profile lines the tidy-up wrote, which later batches may merge into.
  List<(ProfileSection, ProfileItem)> get tidyLines => [
    for (final s in ProfileSection.values)
      for (final i in _sections[s]!)
        if (_tidy.itemIds.contains(i.id)) (s, i),
  ];

  ProfileSection? sectionOf(String itemId) {
    for (final s in ProfileSection.values) {
      if (_sections[s]!.any((i) => i.id == itemId)) return s;
    }
    return null;
  }

  Future<void> load() async {
    final j = await _vault.read(document) as Map<String, Object?>?;
    if (j != null) {
      final sections = j['sections']! as Map;
      for (final s in ProfileSection.values) {
        _sections[s] = [
          for (final i in (sections[s.name] as List?) ?? const [])
            ProfileItem.fromJson(Map<String, Object?>.from(i as Map)),
        ];
      }
      _suggested = [
        for (final i in j['suggested']! as List)
          Suggestion.fromJson(Map<String, Object?>.from(i as Map)),
      ];
      _archived = [
        for (final i in j['archived']! as List)
          ArchivedItem.fromJson(Map<String, Object?>.from(i as Map)),
      ];
      _pending = [
        for (final i in j['pending']! as List)
          PendingMemory.fromJson(Map<String, Object?>.from(i as Map)),
      ];
      _tidy = TidyReport.fromJson(Map<String, Object?>.from(j['tidy']! as Map));
      _tidied = j['tidied'] as int?;
    }
    final legacy = await _vault.read(legacyDocument) as List?;
    _legacy = [
      for (final m in legacy ?? const [])
        LegacyMemory((m as Map)['id']! as String, m['text']! as String),
    ];
    loaded = true;
    revision++;
    notifyListeners();
  }

  Future<void> _save() async {
    revision++;
    notifyListeners();
    await _vault.write(document, {
      'sections': {
        for (final s in ProfileSection.values)
          s.name: [for (final i in _sections[s]!) i.toJson()],
      },
      'suggested': [for (final s in _suggested) s.toJson()],
      'archived': [for (final a in _archived) a.toJson()],
      'pending': [for (final p in _pending) p.toJson()],
      'tidy': _tidy.toJson(),
      'tidied': _tidied,
    });
  }

  /// Whether a profile line or suggestion already reads [text], ignoring
  /// case and spacing.
  bool knows(String text) {
    final t = _norm(text);
    return items.any((i) => _norm(i.text) == t) ||
        _suggested.any((s) => _norm(s.text) == t);
  }

  static String _norm(String s) =>
      s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  // -- The user's own changes ----------------------------------------------

  Future<void> add(ProfileSection section, String text) {
    final t = text.trim();
    assert(t.isNotEmpty, 'The Memory screen saves only non-blank text');
    _sections[section] = [
      ..._sections[section]!,
      ProfileItem(
        id: newId(),
        text: t,
        origin: MemoryOrigin.manual,
        updated: DateTime.now(),
      ),
    ];
    return _save();
  }

  /// Rewrites line [id]; returns whether it exists and changed.
  Future<bool> edit(String id, String text) async {
    final t = text.trim();
    final s = sectionOf(id);
    if (s == null || t.isEmpty) return false;
    final list = _sections[s]!;
    final i = list.indexWhere((x) => x.id == id);
    if (list[i].text == t) return false;
    _sections[s] = [...list]
      ..[i] = ProfileItem(
        id: id,
        text: t,
        origin: MemoryOrigin.manual,
        updated: DateTime.now(),
      );
    await _save();
    return true;
  }

  Future<void> move(String id, ProfileSection to) async {
    final from = sectionOf(id);
    if (from == null || from == to) return;
    final item = _sections[from]!.firstWhere((x) => x.id == id);
    _sections[from] = [
      for (final x in _sections[from]!)
        if (x.id != id) x,
    ];
    _sections[to] = [..._sections[to]!, item];
    await _save();
  }

  /// Removes line [id] and returns where it was, for [restore].
  Future<(ProfileSection, int, ProfileItem)?> remove(String id) async {
    final s = sectionOf(id);
    if (s == null) return null;
    final list = [..._sections[s]!];
    final i = list.indexWhere((x) => x.id == id);
    final item = list.removeAt(i);
    _sections[s] = list;
    await _save();
    return (s, i, item);
  }

  /// Puts back a line taken out by [remove], where it was.
  Future<void> restore((ProfileSection, int, ProfileItem) removed) {
    final (s, i, item) = removed;
    if (sectionOf(item.id) != null) return Future.value();
    final list = [..._sections[s]!];
    list.insert(i.clamp(0, list.length), item);
    _sections[s] = list;
    return _save();
  }

  /// Puts [update]'s section back as it was before the rewrite, unless it
  /// has changed since; returns whether it did.
  Future<bool> undo(MemoryUpdate update) async {
    if (!_same(_sections[update.section]!, update.after)) return false;
    _sections[update.section] = update.before;
    await _save();
    return true;
  }

  /// Whether [update] can still be undone.
  bool canUndo(MemoryUpdate update) =>
      _same(_sections[update.section]!, update.after);

  static bool _same(List<ProfileItem> a, List<ProfileItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].text != b[i].text) return false;
    }
    return true;
  }

  Future<void> acceptSuggestion(String id) {
    final s = _suggested.firstWhere((x) => x.id == id);
    _suggested = [
      for (final x in _suggested)
        if (x.id != id) x,
    ];
    _sections[s.section] = [
      ..._sections[s.section]!,
      ProfileItem(
        id: newId(),
        text: s.text,
        origin: MemoryOrigin.implied,
        updated: DateTime.now(),
      ),
    ];
    return _save();
  }

  Future<void> dismissSuggestion(String id) {
    _suggested = [
      for (final x in _suggested)
        if (x.id != id) x,
    ];
    return _save();
  }

  /// Puts an archived note back in the profile, in [to] or the section it
  /// came with.
  Future<void> restoreArchived(String id, {ProfileSection? to}) {
    final a = _archived.firstWhere((x) => x.id == id);
    final section = to ?? a.section!;
    _archived = [
      for (final x in _archived)
        if (x.id != id) x,
    ];
    _sections[section] = [
      ..._sections[section]!,
      ProfileItem(
        id: newId(),
        text: a.text,
        origin: MemoryOrigin.imported,
        updated: DateTime.now(),
      ),
    ];
    return _save();
  }

  Future<void> deleteArchived(String id) {
    _archived = [
      for (final x in _archived)
        if (x.id != id) x,
    ];
    return _save();
  }

  /// Files a waiting memory by hand, after the model could not.
  Future<void> filePending(String id, ProfileSection section, String text) {
    _pending = [
      for (final p in _pending)
        if (p.id != id) p,
    ];
    return add(section, text);
  }

  Future<void> dropPending(String id) {
    _pending = [
      for (final p in _pending)
        if (p.id != id) p,
    ];
    return _save();
  }

  // -- The model's changes (see MemoryKeeper) ------------------------------

  /// Replaces [section] with [texts]. Lines whose text is unchanged keep
  /// their identity; new text becomes a line of [origin]. Returns null when
  /// nothing changed. The caller checks [revision] first, so the section is
  /// still the one the model rewrote.
  Future<MemoryUpdate?> rewrite(
    ProfileSection section,
    List<String> texts, {
    required MemoryOrigin origin,
  }) async {
    final before = _sections[section]!;
    final unused = [...before];
    final now = DateTime.now();
    final after = <ProfileItem>[];
    for (final t in texts) {
      final i = unused.indexWhere((x) => x.text == t);
      after.add(
        i >= 0
            ? unused.removeAt(i)
            : ProfileItem(id: newId(), text: t, origin: origin, updated: now),
      );
    }
    if (_same(before, after)) return null;
    _sections[section] = after;
    await _save();
    return MemoryUpdate(section, before, after);
  }

  Future<void> suggest(ProfileSection section, String text) {
    _suggested = [
      ..._suggested,
      Suggestion(
        id: newId(),
        section: section,
        text: text,
        created: DateTime.now(),
      ),
    ];
    return _save();
  }

  /// Takes a suggestion out because the model is filing it for good.
  Future<void> promote(String suggestionId) => dismissSuggestion(suggestionId);

  Future<void> queue(PendingMemory memory) {
    _pending = [..._pending, memory];
    return _save();
  }

  /// The model has filed (or found it already knew) pending memory [id].
  Future<void> settle(String id) => dropPending(id);

  /// The model's answer for pending memory [id] failed validation.
  Future<void> failed(String id) {
    _pending = [
      for (final p in _pending)
        p.id == id
            ? PendingMemory(id: p.id, text: p.text, failures: p.failures + 1)
            : p,
    ];
    return _save();
  }

  /// Applies a validated tidy-up [batch] of [notes]. Lines absorbed into a
  /// new line are ones earlier batches wrote, so undoing the tidy-up can
  /// always put the original notes back.
  Future<void> applyTidy(List<LegacyMemory> notes, TidyBatch batch) {
    final now = DateTime.now();
    final text = {for (final n in notes) n.id: n.text};
    final itemIds = {..._tidy.itemIds};
    final archivedIds = {..._tidy.archivedIds};
    final sectionOf = {..._tidy.sectionOf};
    var merged = 0;
    for (final line in batch.keep) {
      for (final id in line.absorbs) {
        final s = this.sectionOf(id)!;
        _sections[s] = [
          for (final x in _sections[s]!)
            if (x.id != id) x,
        ];
        itemIds.remove(id);
      }
      final item = ProfileItem(
        id: newId(),
        text: line.text,
        origin: MemoryOrigin.imported,
        updated: now,
      );
      _sections[line.section] = [..._sections[line.section]!, item];
      itemIds.add(item.id);
      for (final n in line.notes) {
        sectionOf[n] = line.section;
      }
      merged += line.notes.length + line.absorbs.length - 1;
    }
    for (final (:note, :section) in batch.setAside) {
      final a = ArchivedItem(
        id: newId(),
        text: text[note]!,
        section: section,
        archived: now,
      );
      _archived = [..._archived, a];
      archivedIds.add(a.id);
      sectionOf[note] = section;
    }
    _tidy = TidyReport(
      processed: {..._tidy.processed, ...text.keys},
      sectionOf: sectionOf,
      itemIds: itemIds,
      archivedIds: archivedIds,
      // Lines absorbed into another were counted as kept by their batch.
      kept: _tidy.kept + batch.keep.length - _absorbedCount(batch),
      merged: _tidy.merged + merged,
      setAside: _tidy.setAside + batch.setAside.length,
    );
    _finishTidyIfDone();
    return _save();
  }

  static int _absorbedCount(TidyBatch batch) =>
      batch.keep.fold(0, (n, l) => n + l.absorbs.length);

  /// The model's answer for the current tidy-up batch failed validation.
  Future<void> tidyFailed() {
    _tidy = TidyReport(
      processed: _tidy.processed,
      sectionOf: _tidy.sectionOf,
      itemIds: _tidy.itemIds,
      archivedIds: _tidy.archivedIds,
      kept: _tidy.kept,
      merged: _tidy.merged,
      setAside: _tidy.setAside,
      failures: _tidy.failures + 1,
    );
    return _save();
  }

  /// Sets [notes] aside unsorted after the model failed to sort them, for
  /// the user to place on restore.
  Future<void> setAsideUnsorted(List<LegacyMemory> notes) {
    final now = DateTime.now();
    final archivedIds = {..._tidy.archivedIds};
    for (final n in notes) {
      final a = ArchivedItem(
        id: newId(),
        text: n.text,
        section: null,
        archived: now,
      );
      _archived = [..._archived, a];
      archivedIds.add(a.id);
    }
    _tidy = TidyReport(
      processed: {..._tidy.processed, for (final n in notes) n.id},
      sectionOf: _tidy.sectionOf,
      itemIds: _tidy.itemIds,
      archivedIds: archivedIds,
      kept: _tidy.kept,
      merged: _tidy.merged,
      setAside: _tidy.setAside + notes.length,
    );
    _finishTidyIfDone();
    return _save();
  }

  void _finishTidyIfDone() {
    if (_legacy.every((m) => _tidy.processed.contains(m.id))) {
      _tidied = tidyVersion;
    }
  }

  /// The user is happy with the tidy-up: the old document goes.
  Future<void> confirmTidy() async {
    await _vault.delete(legacyDocument);
    _legacy = const [];
    _tidy = const TidyReport();
    await _save();
  }

  /// Puts every old note back as it was written, in the section the
  /// tidy-up chose for it, and removes what the tidy-up wrote. Notes it
  /// could not place stay in Archived for the user to place.
  Future<void> undoTidy() async {
    final now = DateTime.now();
    for (final s in ProfileSection.values) {
      _sections[s] = [
        for (final x in _sections[s]!)
          if (!_tidy.itemIds.contains(x.id)) x,
      ];
    }
    _archived = [
      for (final a in _archived)
        if (!_tidy.archivedIds.contains(a.id) || a.section == null) a,
    ];
    for (final m in _legacy) {
      final s = _tidy.sectionOf[m.id];
      if (s == null) continue;
      _sections[s] = [
        ..._sections[s]!,
        ProfileItem(
          id: newId(),
          text: m.text,
          origin: MemoryOrigin.imported,
          updated: now,
        ),
      ];
    }
    await confirmTidy();
  }
}
