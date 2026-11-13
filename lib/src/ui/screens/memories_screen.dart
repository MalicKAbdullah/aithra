import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';

import '../../memory/memory_store.dart';
import '../../services.dart';
import '../aithra_type.dart';

/// What Aithra remembers about the user. The model keeps this list itself;
/// here the user reads, corrects, deletes or adds to it, or turns memory
/// off altogether.
class MemoriesScreen extends StatelessWidget {
  const MemoriesScreen({super.key});

  Future<void> _edit(BuildContext context, {Memory? memory}) async {
    final store = context.services.memories;
    final controller = TextEditingController(text: memory?.text ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(memory == null ? 'New memory' : 'Edit memory'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'e.g. I prefer metric units',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    if (memory == null) {
      await store.add(text);
    } else {
      await store.edit(memory.id, text);
    }
  }

  Future<void> _delete(BuildContext context, Memory m) async {
    final store = context.services.memories;
    final messenger = ScaffoldMessenger.of(context);
    final removed = await store.remove(m.id);
    if (removed == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Memory deleted'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => store.restore(removed.$1, removed.$2),
          ),
        ),
      );
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
                onPressed: () => _edit(context),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add memory'),
              )
            : const SizedBox.shrink(),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([store, s.settings]),
        builder: (context, _) {
          final items = store.items;
          final on = s.settings.memoryEnabled;
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
                      'Lasting facts and preferences from your chats, used in '
                      'new ones along with your past chats',
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
                    ? 'Aithra decides what is worth remembering. Everything '
                          'is encrypted on this phone; tap one to correct it, '
                          'or swipe it away to forget it.'
                    : 'Memory is off: Aithra neither saves nor uses these '
                          'until you turn it back on.',
                style: AithraType.bodySmall.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.md),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.xl),
                  child: AppEmptyState(
                    title: 'Nothing remembered yet',
                    message:
                        'As you chat, Aithra keeps what will help next time: '
                        'your name, what you are working on, how you like '
                        'answers.',
                    icon: Icons.auto_awesome_outlined,
                    compact: true,
                  ),
                )
              else
                RowGroup(
                  separatorIndent: AppSpacing.md,
                  children: [
                    for (final m in items)
                      Dismissible(
                        key: ValueKey(m.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: c.negativeContainer,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: AppSpacing.md),
                          child: Icon(
                            Icons.delete_outline_rounded,
                            color: c.negative,
                          ),
                        ),
                        onDismissed: (_) => _delete(context, m),
                        child: _MemoryRow(
                          memory: m,
                          onTap: () => _edit(context, memory: m),
                          onDelete: () => _delete(context, m),
                        ),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MemoryRow extends StatelessWidget {
  const _MemoryRow({
    required this.memory,
    required this.onTap,
    required this.onDelete,
  });

  final Memory memory;
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
                  memory.text,
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
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
