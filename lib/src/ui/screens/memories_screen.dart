import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';

import '../../memory/memory_store.dart';
import '../../memory/profile.dart';
import '../../services.dart';
import '../aithra_type.dart';
import '../widgets/section_label.dart';

/// What Aithra knows about the user, as a profile in sections. The model
/// keeps it; here the user reads, corrects, moves or deletes lines, accepts
/// or dismisses suggestions, restores what was set aside, and reviews the
/// one-time tidy-up of older memories.
class MemoriesScreen extends StatefulWidget {
  const MemoriesScreen({super.key});

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  bool _showArchived = false;
  final _archivedKey = GlobalKey();

  MemoryStore get _store => context.services.memories;

  void _snack(String text, {VoidCallback? undo}) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(text),
            action: undo == null
                ? null
                : SnackBarAction(label: 'Undo', onPressed: undo),
          ),
        );

  Future<void> _add() async {
    final r = await _LineDialog.show(context, title: 'New memory');
    if (r == null) return;
    await _store.add(r.$1, r.$2);
  }

  Future<void> _edit(ProfileSection section, ProfileItem item) async {
    final r = await _LineDialog.show(
      context,
      title: 'Edit memory',
      text: item.text,
      section: section,
    );
    if (r == null) return;
    await _store.edit(item.id, r.$2);
    if (r.$1 != section) await _store.move(item.id, r.$1);
  }

  Future<void> _delete(ProfileItem item) async {
    final store = _store;
    final removed = await store.remove(item.id);
    if (removed == null || !mounted) return;
    _snack('Memory deleted', undo: () => store.restore(removed));
  }

  Future<void> _filePending(PendingMemory p) async {
    final r = await _LineDialog.show(
      context,
      title: 'File memory',
      text: p.text,
    );
    if (r == null) return;
    await _store.filePending(p.id, r.$1, r.$2);
  }

  Future<void> _restore(ArchivedItem a) async {
    final to = a.section ?? await _pickSection(context);
    if (to == null) return;
    await _store.restoreArchived(a.id, to: to);
    if (mounted) _snack('Restored to ${to.label}');
  }

  Future<void> _review() async {
    setState(() => _showArchived = true);
    await WidgetsBinding.instance.endOfFrame;
    final target = _archivedKey.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        duration: AppMotion.slow,
        curve: AppMotion.standard,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final store = s.memories;
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Memory')),
      floatingActionButton: ListenableBuilder(
        listenable: s.settings,
        builder: (context, _) => s.settings.memoryEnabled
            ? FloatingActionButton.extended(
                heroTag: 'add-memory',
                onPressed: _add,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add memory'),
              )
            : const SizedBox.shrink(),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([store, s.settings, s.keeper.failure]),
        builder: (context, _) {
          final on = s.settings.memoryEnabled;
          final report = store.tidyReport;
          final waiting = [...store.pending];
          final untidied = store.untidied.length;
          final empty =
              store.count == 0 &&
              store.suggested.isEmpty &&
              waiting.isEmpty &&
              untidied == 0;
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              0,
              AppSpacing.gutter,
              112,
            ),
            children: [
              RowGroup(
                separatorIndent: AppSpacing.md,
                children: [
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    title: const Text('Remember things about me'),
                    subtitle: const Text(
                      'Who you are, what you do and what you like, used in '
                      'new chats along with your past chats',
                    ),
                    value: on,
                    onChanged: (v) =>
                        s.settings.update((x) => x.memoryEnabled = v),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                on
                    ? 'Aithra remembers what you tell it about yourself or ask '
                          'it to remember, not your questions. Everything is '
                          'encrypted on this phone; tap a line to correct it, '
                          'or swipe it away to forget it.'
                    : 'Memory is off: Aithra neither saves nor uses these '
                          'until you turn it back on.',
                style: AithraType.bodySmall.copyWith(color: c.textSecondary),
              ),
              if (s.keeper.failure.value case final failure?) ...[
                const SizedBox(height: AppSpacing.md),
                AppBanner(
                  kind: BannerKind.error,
                  title: 'Memory could not update',
                  message: failure,
                ),
              ],
              if (untidied > 0) ...[
                const SizedBox(height: AppSpacing.md),
                AppBanner(
                  icon: Icons.auto_awesome_outlined,
                  title: 'Sorting your older memories',
                  message:
                      '$untidied left. Aithra files them into sections while '
                      'it is not answering you; nothing is deleted.',
                ),
              ],
              if (report != null) ...[
                const SizedBox(height: AppSpacing.md),
                TidyBanner(
                  report: report,
                  onReview: _review,
                  onUndo: () async {
                    await store.undoTidy();
                    if (context.mounted) _snack('Older memories put back');
                  },
                  onDone: store.confirmTidy,
                ),
              ],
              if (store.suggested.isNotEmpty || waiting.isNotEmpty) ...[
                const SectionLabel('Suggested'),
                RowGroup(
                  separatorIndent: AppSpacing.md,
                  children: [
                    for (final p in waiting)
                      _PendingRow(
                        pending: p,
                        onTap: p.stuck ? () => _filePending(p) : null,
                        onDrop: () => store.dropPending(p.id),
                      ),
                    for (final sug in store.suggested)
                      _SuggestionRow(
                        suggestion: sug,
                        onAccept: () => store.acceptSuggestion(sug.id),
                        onDismiss: () => store.dismissSuggestion(sug.id),
                      ),
                  ],
                ),
              ],
              for (final section in ProfileSection.values)
                if (store.section(section).isNotEmpty) ...[
                  SectionLabel(section.label),
                  RowGroup(
                    separatorIndent: AppSpacing.md,
                    children: [
                      for (final item in store.section(section))
                        Dismissible(
                          key: ValueKey(item.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: c.negativeContainer,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(
                              right: AppSpacing.md,
                            ),
                            child: Icon(
                              Icons.delete_outline_rounded,
                              color: c.negative,
                            ),
                          ),
                          onDismissed: (_) => _delete(item),
                          child: _MemoryRow(
                            text: item.text,
                            onTap: () => _edit(section, item),
                            onDelete: () => _delete(item),
                          ),
                        ),
                    ],
                  ),
                ],
              if (empty)
                const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.xl),
                  child: AppEmptyState(
                    title: 'Nothing remembered yet',
                    message:
                        'Tell Aithra your name, what you do or what you are '
                        'into, or ask it to remember something.',
                    icon: Icons.auto_awesome_outlined,
                    compact: true,
                  ),
                ),
              if (store.archived.isNotEmpty) ...[
                SectionLabel(
                  'Set aside',
                  key: _archivedKey,
                  trailing: TextButton(
                    onPressed: () =>
                        setState(() => _showArchived = !_showArchived),
                    child: Text(
                      _showArchived ? 'Hide' : 'Show ${store.archived.length}',
                    ),
                  ),
                ),
                if (_showArchived)
                  RowGroup(
                    separatorIndent: AppSpacing.md,
                    children: [
                      for (final a in store.archived)
                        _ArchivedRow(
                          item: a,
                          onRestore: () => _restore(a),
                          onDelete: () => store.deleteArchived(a.id),
                        ),
                    ],
                  )
                else
                  Text(
                    'Notes Aithra kept out of your profile. Restore any of '
                    'them in one tap.',
                    style: AithraType.bodySmall.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// What the one-time tidy-up of older memories did, until the user keeps
/// it or puts everything back.
class TidyBanner extends StatelessWidget {
  const TidyBanner({
    required this.report,
    required this.onReview,
    required this.onUndo,
    required this.onDone,
    super.key,
  });

  final TidyReport report;
  final VoidCallback onReview;
  final VoidCallback onUndo;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        side: BorderSide(color: c.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.auto_awesome_outlined,
                    size: 20,
                    color: accent,
                  ),
                ),
                const SizedBox(width: AppSpacing.smd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Aithra tidied your memory',
                        style: AithraType.title.copyWith(color: c.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Kept ${report.kept}, merged ${report.merged}, set '
                        'aside ${report.setAside}. Nothing was deleted.',
                        style: AithraType.bodySmall.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(onPressed: onUndo, child: const Text('Undo')),
                TextButton(onPressed: onReview, child: const Text('Review')),
                TextButton(onPressed: onDone, child: const Text('Looks good')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryRow extends StatelessWidget {
  const _MemoryRow({
    required this.text,
    required this.onTap,
    required this.onDelete,
  });

  final String text;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: AppSpacing.md, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.smd),
                child: Text(
                  text,
                  style: AithraType.body.copyWith(color: c.textPrimary),
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              padding: EdgeInsets.zero,
              icon: Icon(Icons.more_vert_rounded, color: c.textTertiary),
              onSelected: (v) => v == 'edit' ? onTap() : onDelete(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit or move')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A row with a line of text, a quiet caption and trailing actions.
class _CaptionedRow extends StatelessWidget {
  const _CaptionedRow({
    required this.text,
    required this.caption,
    required this.actions,
    this.onTap,
    this.muted = false,
  });

  final String text;
  final String caption;
  final List<Widget> actions;
  final VoidCallback? onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: AppSpacing.md, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.smd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text,
                      style: AithraType.body.copyWith(
                        color: muted ? c.textSecondary : c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      style: AithraType.caption.copyWith(color: c.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.suggestion,
    required this.onAccept,
    required this.onDismiss,
  });

  final Suggestion suggestion;
  final VoidCallback onAccept;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return _CaptionedRow(
      text: suggestion.text,
      caption: '${suggestion.section.label} · from what you said',
      actions: [
        IconButton(
          tooltip: 'Dismiss',
          onPressed: onDismiss,
          icon: Icon(Icons.close_rounded, color: c.textTertiary),
        ),
        IconButton(
          tooltip: 'Remember',
          onPressed: onAccept,
          icon: Icon(
            Icons.check_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow({
    required this.pending,
    required this.onTap,
    required this.onDrop,
  });

  final PendingMemory pending;
  final VoidCallback? onTap;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return _CaptionedRow(
      text: pending.text,
      caption: pending.stuck
          ? 'Aithra could not file this. Tap to choose a section.'
          : 'You asked Aithra to remember this. Filing it when Aithra is free.',
      onTap: onTap,
      actions: [
        IconButton(
          tooltip: 'Forget',
          onPressed: onDrop,
          icon: Icon(Icons.close_rounded, color: c.textTertiary),
        ),
      ],
    );
  }
}

class _ArchivedRow extends StatelessWidget {
  const _ArchivedRow({
    required this.item,
    required this.onRestore,
    required this.onDelete,
  });

  final ArchivedItem item;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return _CaptionedRow(
      text: item.text,
      caption: item.section?.label ?? 'Not sorted',
      muted: true,
      actions: [
        IconButton(
          tooltip: 'Delete',
          onPressed: onDelete,
          icon: Icon(Icons.delete_outline_rounded, color: c.textTertiary),
        ),
        TextButton(onPressed: onRestore, child: const Text('Restore')),
      ],
    );
  }
}

Future<ProfileSection?> _pickSection(BuildContext context) =>
    showModalBottomSheet<ProfileSection>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in ProfileSection.values)
              ListTile(
                title: Text(s.label),
                onTap: () => Navigator.pop(context, s),
              ),
          ],
        ),
      ),
    );

/// Asks for a profile line and the section it goes in.
class _LineDialog extends StatefulWidget {
  const _LineDialog({required this.title, this.text, this.section});

  final String title;
  final String? text;
  final ProfileSection? section;

  static Future<(ProfileSection, String)?> show(
    BuildContext context, {
    required String title,
    String? text,
    ProfileSection? section,
  }) => showDialog<(ProfileSection, String)>(
    context: context,
    builder: (_) => _LineDialog(title: title, text: text, section: section),
  );

  @override
  State<_LineDialog> createState() => _LineDialogState();
}

class _LineDialogState extends State<_LineDialog> {
  late final _controller = TextEditingController(text: widget.text ?? '');
  late ProfileSection _section = widget.section ?? ProfileSection.about;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 4,
              minLines: 1,
              maxLength: 160,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'e.g. Prefers metric units',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Section',
              style: AithraType.section.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final s in ProfileSection.values)
                  ChoiceChip(
                    label: Text(s.label),
                    selected: s == _section,
                    onSelected: (_) => setState(() => _section = s),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => FilledButton(
            onPressed: _controller.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, (_section, _controller.text)),
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}
