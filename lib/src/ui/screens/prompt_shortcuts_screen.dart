import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../../data/prompt_shortcut.dart';
import '../../services.dart';
import '../aithra_type.dart';

/// Add, edit, reorder and remove the prompt shortcuts.
class PromptShortcutsScreen extends StatelessWidget {
  const PromptShortcutsScreen({super.key});

  Future<void> _save(BuildContext context, List<PromptShortcut> list) =>
      context.services.settings.update((s) => s.promptShortcuts = list);

  Future<void> _edit(BuildContext context, {int? index}) async {
    final list = context.services.settings.promptShortcuts;
    final result = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _EditDialog(existing: index == null ? null : list[index]),
    );
    if (result == null || !context.mounted) return;
    final next = [...list];
    switch (result) {
      case _Save(:final shortcut):
        if (index == null) {
          next.add(shortcut);
        } else {
          next[index] = shortcut;
        }
      case _Delete():
        next.removeAt(index!);
    }
    await _save(context, next);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prompt shortcuts'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (_) => _save(context, defaultPromptShortcuts),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reset', child: Text('Restore defaults')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add shortcut'),
      ),
      body: ListenableBuilder(
        listenable: s.settings,
        builder: (context, _) {
          final list = s.settings.promptShortcuts;
          return ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.xs,
              AppSpacing.sm,
              96,
            ),
            header: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.md,
              ),
              child: Text(
                'Shortcuts show as chips on a new chat and when you ask '
                'Aithra about selected text. Tapping one puts its prompt in '
                'the message box.',
                style: AithraType.bodySmall.copyWith(color: c.textSecondary),
              ),
            ),
            itemCount: list.length,
            onReorder: (from, to) {
              final next = [...list];
              final item = next.removeAt(from);
              next.insert(to > from ? to - 1 : to, item);
              _save(context, next);
            },
            itemBuilder: (context, i) => ListTile(
              key: ValueKey(('shortcut', i, list[i])),
              title: Text(list[i].label),
              subtitle: Text(
                list[i].prompt.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _edit(context, index: i),
              trailing: ReorderableDragStartListener(
                index: i,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: Icon(
                    Icons.drag_handle_rounded,
                    color: c.textTertiary,
                    semanticLabel: 'Reorder',
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

sealed class _EditResult {}

class _Save extends _EditResult {
  _Save(this.shortcut);
  final PromptShortcut shortcut;
}

class _Delete extends _EditResult {}

class _EditDialog extends StatefulWidget {
  const _EditDialog({this.existing});

  final PromptShortcut? existing;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final _label = TextEditingController(text: widget.existing?.label);
  late final _prompt = TextEditingController(text: widget.existing?.prompt);

  @override
  void dispose() {
    _label.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New shortcut' : 'Edit shortcut'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _label,
              autofocus: widget.existing == null,
              maxLength: 24,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Chip label'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _prompt,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Prompt',
                hintText: 'Rewrite this so it sounds friendlier: ',
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            onPressed: () => Navigator.pop(context, _Delete()),
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_label, _prompt]),
          builder: (context, _) => FilledButton(
            onPressed: _label.text.trim().isEmpty || _prompt.text.trim().isEmpty
                ? null
                : () => Navigator.pop(
                    context,
                    _Save(PromptShortcut(_label.text.trim(), _prompt.text)),
                  ),
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}
