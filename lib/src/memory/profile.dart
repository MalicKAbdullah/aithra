/// The parts of the user's profile. Their order is the order the profile is
/// shown in and given to the model: who the user is and how they want
/// answers come first, so they are the last to be left out of a full
/// prompt.
enum ProfileSection {
  about('About you', 'who they are: name, age, family, home, languages'),
  preferences(
    'Preferences',
    'how they like answers, and lasting likes and dislikes',
  ),
  work('Work and studies', 'their job, studies, workplace and skills'),
  interests('Interests', 'hobbies and lasting interests'),
  projects('Projects', 'things they are working on over weeks or months');

  const ProfileSection(this.label, this.meaning);

  /// The heading on the Memory screen.
  final String label;

  /// What belongs here, as the model is told.
  final String meaning;

  static ProfileSection? byName(Object? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// How a profile line came to be.
enum MemoryOrigin {
  /// The user said it about themselves.
  stated,

  /// The user asked Aithra to remember it.
  asked,

  /// Hinted at twice, or accepted from Suggested.
  implied,

  /// Typed or edited on the Memory screen.
  manual,

  /// Sorted in from the memories kept before the profile existed.
  imported;

  static MemoryOrigin byName(Object? name) =>
      values.firstWhere((o) => o.name == name);
}

/// One line of the profile.
class ProfileItem {
  const ProfileItem({
    required this.id,
    required this.text,
    required this.origin,
    required this.updated,
  });

  factory ProfileItem.fromJson(Map<String, Object?> j) => ProfileItem(
    id: j['id']! as String,
    text: j['text']! as String,
    origin: MemoryOrigin.byName(j['origin']),
    updated: DateTime.fromMillisecondsSinceEpoch(j['updated']! as int),
  );

  final String id;
  final String text;
  final MemoryOrigin origin;
  final DateTime updated;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'origin': origin.name,
    'updated': updated.millisecondsSinceEpoch,
  };
}

/// Something the user's words hinted at but did not say. It stays out of
/// prompts until the user accepts it or hints at it again.
class Suggestion {
  const Suggestion({
    required this.id,
    required this.section,
    required this.text,
    required this.created,
  });

  factory Suggestion.fromJson(Map<String, Object?> j) => Suggestion(
    id: j['id']! as String,
    section: ProfileSection.byName(j['section'])!,
    text: j['text']! as String,
    created: DateTime.fromMillisecondsSinceEpoch(j['created']! as int),
  );

  final String id;
  final ProfileSection section;
  final String text;
  final DateTime created;

  Map<String, Object?> toJson() => {
    'id': id,
    'section': section.name,
    'text': text,
    'created': created.millisecondsSinceEpoch,
  };
}

/// A line kept out of the profile but not deleted: a note the tidy-up set
/// aside. [section] is where it goes back to; null when the model never
/// placed it, and the user picks one on restore.
class ArchivedItem {
  const ArchivedItem({
    required this.id,
    required this.text,
    required this.section,
    required this.archived,
  });

  factory ArchivedItem.fromJson(Map<String, Object?> j) => ArchivedItem(
    id: j['id']! as String,
    text: j['text']! as String,
    section: ProfileSection.byName(j['section']),
    archived: DateTime.fromMillisecondsSinceEpoch(j['archived']! as int),
  );

  final String id;
  final String text;
  final ProfileSection? section;
  final DateTime archived;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'section': section?.name,
    'archived': archived.millisecondsSinceEpoch,
  };
}

/// Something the user asked Aithra to remember, waiting for the engine to
/// be free so the model can file it into the profile.
class PendingMemory {
  const PendingMemory({
    required this.id,
    required this.text,
    this.failures = 0,
  });

  factory PendingMemory.fromJson(Map<String, Object?> j) => PendingMemory(
    id: j['id']! as String,
    text: j['text']! as String,
    failures: j['failures']! as int,
  );

  final String id;
  final String text;

  /// Model answers that failed validation. After [MemoryPolicy.attempts]
  /// the user files it by hand.
  final int failures;

  bool get stuck => failures >= MemoryPolicy.attempts;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'failures': failures,
  };
}

abstract final class MemoryPolicy {
  /// Lines a section may grow to through the model; the user may add more.
  static const int sectionCap = 8;

  static const int minChars = 3;
  static const int maxChars = 160;

  /// Existing lines one rewrite may change or drop.
  static const int maxChanged = 2;

  /// Invalid model answers for one piece of work before it is handed to
  /// the user instead.
  static const int attempts = 2;
}

/// One rewrite of a section, kept so it can be undone while the section
/// still reads as the rewrite left it.
class MemoryUpdate {
  const MemoryUpdate(this.section, this.before, this.after);

  final ProfileSection section;
  final List<ProfileItem> before;
  final List<ProfileItem> after;
}

/// What the one-time tidy-up of the old flat memory list did; the banner
/// on the Memory screen shows it until the user says it looks right or
/// undoes it.
class TidyReport {
  const TidyReport({
    this.processed = const {},
    this.sectionOf = const {},
    this.itemIds = const {},
    this.archivedIds = const {},
    this.kept = 0,
    this.merged = 0,
    this.setAside = 0,
    this.failures = 0,
  });

  factory TidyReport.fromJson(Map<String, Object?> j) => TidyReport(
    processed: {...(j['processed']! as List).cast<String>()},
    sectionOf: {
      for (final e in (j['sectionOf']! as Map).entries)
        e.key as String: ProfileSection.byName(e.value)!,
    },
    itemIds: {...(j['itemIds']! as List).cast<String>()},
    archivedIds: {...(j['archivedIds']! as List).cast<String>()},
    kept: j['kept']! as int,
    merged: j['merged']! as int,
    setAside: j['setAside']! as int,
    failures: j['failures']! as int,
  );

  /// Old memory ids already sorted or set aside.
  final Set<String> processed;

  /// The section each sorted old memory went to, so undoing the tidy-up
  /// can put each one back as it was written.
  final Map<String, ProfileSection> sectionOf;

  /// Profile lines and archived notes the tidy-up created.
  final Set<String> itemIds;
  final Set<String> archivedIds;

  final int kept;
  final int merged;
  final int setAside;

  /// Invalid model answers for the batch now being sorted.
  final int failures;

  bool get changedAnything => kept + merged + setAside > 0;

  Map<String, Object?> toJson() => {
    'processed': [...processed],
    'sectionOf': {for (final e in sectionOf.entries) e.key: e.value.name},
    'itemIds': [...itemIds],
    'archivedIds': [...archivedIds],
    'kept': kept,
    'merged': merged,
    'setAside': setAside,
    'failures': failures,
  };
}

/// A memory from before the profile: one flat line.
class LegacyMemory {
  const LegacyMemory(this.id, this.text);
  final String id;
  final String text;
}
