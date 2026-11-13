import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';

import '../../memory/memory_store.dart';
import '../../services.dart';
import '../aithra_type.dart';

/// Facts Aithra remembers about the user, included in every chat.
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
    final store = context.services.memories;
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Memories')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-memory',
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add memory'),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final items = store.items;
          if (items.isEmpty) {
            return const AppEmptyState(
              title: 'Nothing remembered yet',
              message:
                  'Tell Aithra things like "my name is Sam" and it will '
                  'offer to remember them. Long-press any message to save it.',
              icon: Icons.bookmark_outline_rounded,
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              0,
              AppSpacing.gutter,
              112,
            ),
            children: [
              Text(
                'Stored encrypted on this phone and added to every chat. '
                'Swipe one away to forget it.',
                style: AithraType.bodySmall.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.md),
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
        padding: const EdgeInsets.only(left: AppSpacing.md),
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
