import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_models.dart';
import '../../models/catalog.dart';
import '../../models/download_state.dart';
import '../../services.dart';
import '../widgets/aithra_mark.dart';
import 'chat_screen.dart';
import 'models_screen.dart';
import 'settings_screen.dart';
import 'voice_mode_screen.dart';

/// The conversation list.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) context.services.chats.loadMore();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _open(ConversationInfo? c) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChatScreen(conversation: c)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            AithraMark(size: 28),
            SizedBox(width: AppSpacing.smd),
            Text('Aithra'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Voice mode',
            icon: const Icon(Icons.graphic_eq_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const VoiceModeScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-chat',
        onPressed: () {
          HapticFeedback.selectionClick();
          _open(null);
        },
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New chat'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              0,
              AppSpacing.gutter,
              AppSpacing.sm,
            ),
            child: SearchBar(
              hintText: 'Search chats',
              leading: Icon(Icons.search_rounded, color: c.textTertiary),
              onChanged: s.chats.search,
            ),
          ),
          const _StatusBanner(),
          Expanded(
            child: ListenableBuilder(
              listenable: s.chats,
              builder: (context, _) {
                final items = s.chats.items;
                if (items.isEmpty) {
                  return s.chats.searching
                      ? const AppEmptyState(
                          title: 'No matches',
                          message: 'Try another word.',
                          icon: Icons.search_off_rounded,
                          compact: true,
                        )
                      : AppEmptyState(
                          title: 'Ask me anything',
                          message:
                              'Your chats appear here, encrypted on this phone.',
                          icon: Icons.chat_bubble_outline_rounded,
                          action: FilledButton(
                            onPressed: () => _open(null),
                            child: const Text('Start a chat'),
                          ),
                        );
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: items.length,
                  itemBuilder: (context, i) => _ConversationRow(
                    key: ValueKey(items[i].id),
                    info: items[i],
                    onTap: () => _open(items[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({required this.info, required this.onTap, super.key});

  final ConversationInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return ListTile(
      onTap: onTap,
      onLongPress: () => _actions(context),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      title: Text(info.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        info.draft?.isNotEmpty == true
            ? 'Draft: ${info.draft}'
            : _when(info.updated),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: info.pinned
          ? Icon(Icons.push_pin_rounded, size: 18, color: c.accent)
          : null,
    );
  }

  static String _when(DateTime t) {
    final now = DateTime.now();
    final d = now.difference(t);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1 && now.day == t.day) {
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    if (d.inDays < 7) {
      return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday -
          1];
    }
    return '${t.day}/${t.month}/${t.year}';
  }

  Future<void> _actions(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final chats = context.services.chats;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                info.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
              ),
              title: Text(info.pinned ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.pop(context, 'pin'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'pin':
        await chats.setPinned(info.id, !info.pinned);
      case 'rename':
        final title = await renameDialog(context, info.title);
        if (title != null && title.isNotEmpty) {
          await chats.rename(info.id, title);
        }
      case 'delete':
        await chats.delete(info.id);
    }
  }
}

Future<String?> renameDialog(BuildContext context, String current) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename chat'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// What stands between the user and a reply: no model, a download, or tuning.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner();

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.models, s.assistant]),
      builder: (context, _) {
        if (!s.models.loaded) return const SizedBox.shrink();
        final tuning = s.assistant.calibrating;
        Widget banner(
          String title,
          String message, {
          VoidCallback? onTap,
          String? action,
        }) => Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.sm,
          ),
          child: AppBanner(
            title: title,
            message: message,
            actionLabel: action,
            onAction: onTap,
          ),
        );
        void openModels() => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const ModelsScreen()));
        if (tuning != null) {
          return banner(
            'Tuning for your phone',
            'Testing ${tuning.label} (${tuning.done + 1} of ${tuning.total}). Chats work once this finishes.',
          );
        }
        if (s.assistant.activeModel != null) return const SizedBox.shrink();
        final download = s.models.availability(defaultModel);
        if (download is Downloading) {
          final pct = ((download.fraction ?? 0) * 100).round();
          return banner(
            'Downloading ${defaultModel.name}',
            download.waitingReason ?? '$pct% · you can leave the app',
            onTap: openModels,
            action: 'Details',
          );
        }
        return banner(
          'No model yet',
          'Download one to start chatting.',
          onTap: openModels,
          action: 'Models',
        );
      },
    );
  }
}
