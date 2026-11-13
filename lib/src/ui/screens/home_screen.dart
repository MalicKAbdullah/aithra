import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_models.dart';
import '../../models/catalog.dart';
import '../../models/download_state.dart';
import '../../services.dart';
import '../aithra_type.dart';
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
            AithraMark(size: 30),
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
              constraints: const BoxConstraints(minHeight: 46),
              textStyle: WidgetStatePropertyAll(
                AithraType.body.copyWith(color: c.textPrimary),
              ),
              hintStyle: WidgetStatePropertyAll(
                AithraType.body.copyWith(color: c.textTertiary),
              ),
              leading: Icon(
                Icons.search_rounded,
                size: 20,
                color: c.textTertiary,
              ),
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
                    match: s.chats.snippets[items[i].id],
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
  const _ConversationRow({
    required this.info,
    required this.onTap,
    this.match,
    super.key,
  });

  final ConversationInfo info;

  /// While searching, the message that matched (rather than the title).
  final String? match;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final draft = info.draft?.isNotEmpty == true ? info.draft : null;
    final preview = info.preview;
    final secondary = AithraType.bodySmall.copyWith(color: c.textSecondary);
    return InkWell(
      onTap: onTap,
      onLongPress: () => _actions(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 68),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.gutter,
            vertical: AppSpacing.smd - 2,
          ),
          child: Row(
            children: [
              _Monogram(info),
              const SizedBox(width: AppSpacing.smd + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            info.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AithraType.title.copyWith(
                              color: c.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          friendlyDate(info.updated, DateTime.now()),
                          style: AithraType.caption.copyWith(
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            match != null
                                ? TextSpan(
                                    children: [
                                      WidgetSpan(
                                        alignment: PlaceholderAlignment.middle,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            right: 4,
                                          ),
                                          child: Icon(
                                            Icons.search_rounded,
                                            size: 14,
                                            color: c.accent,
                                          ),
                                        ),
                                      ),
                                      TextSpan(text: match),
                                    ],
                                  )
                                : draft != null
                                ? TextSpan(
                                    children: [
                                      TextSpan(
                                        text: 'Draft  ',
                                        style: TextStyle(
                                          color: c.accent,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      TextSpan(text: draft),
                                    ],
                                  )
                                : TextSpan(
                                    text: preview == null
                                        ? 'No messages yet'
                                        : info.previewFromUser
                                        ? 'You: $preview'
                                        : preview,
                                  ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: secondary,
                          ),
                        ),
                        if (info.pinned) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Icon(
                            Icons.push_pin_rounded,
                            size: 14,
                            color: c.textTertiary,
                            semanticLabel: 'Pinned',
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

/// A chat's leading tile: its first letter on a soft tint. The tint is
/// picked from the id, so a chat keeps its colour as it moves in the list.
class _Monogram extends StatelessWidget {
  const _Monogram(this.info);

  final ConversationInfo info;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final tints = [c.accent, c.info, c.positive, c.warning, c.textSecondary];
    final tint =
        tints[info.id.codeUnits.fold(0, (a, b) => a + b) % tints.length];
    final title = info.title.trim();
    final letter = title.isEmpty
        ? '·'
        : String.fromCharCode(title.runes.first).toUpperCase();
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Text(
        letter,
        style: AithraType.labelStrong.copyWith(color: tint, fontSize: 15),
      ),
    );
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
