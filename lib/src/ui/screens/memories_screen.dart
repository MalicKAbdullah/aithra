import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';

import '../../memory/memory_store.dart';
import '../../services.dart';

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

  @override
  Widget build(BuildContext context) {
    final store = context.services.memories;
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Memories')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context),
        tooltip: 'Add memory',
        child: const Icon(Icons.add_rounded),
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
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: items.length + 1,
            separatorBuilder: (_, i) =>
                i == 0 ? const SizedBox.shrink() : const Divider(),
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    0,
                    AppSpacing.gutter,
                    AppSpacing.md,
                  ),
                  child: Text(
                    'Stored encrypted on this phone and added to every chat.',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                );
              }
              final m = items[i - 1];
              return Dismissible(
                key: ValueKey(m.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: c.negativeContainer,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: AppSpacing.gutter),
                  child: Icon(Icons.delete_outline_rounded, color: c.negative),
                ),
                onDismissed: (_) => store.remove(m.id),
                child: ListTile(
                  title: Text(m.text),
                  onTap: () => _edit(context, memory: m),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => store.remove(m.id),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
