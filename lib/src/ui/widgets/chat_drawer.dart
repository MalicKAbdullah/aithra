import 'dart:math' as math;

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_models.dart';
import '../../services.dart';
import '../aithra_type.dart';
import '../screens/settings_screen.dart';
import 'aithra_mark.dart';

/// One line of the drawer's list: a group heading or a chat.
sealed class DrawerRow {
  const DrawerRow();
}

class DrawerHeading extends DrawerRow {
  const DrawerHeading(this.label);
  final String label;
}

class DrawerChat extends DrawerRow {
  const DrawerChat(this.info);
  final ConversationInfo info;
}

/// [chats] (pinned first, then newest first) under Pinned / Today /
/// Yesterday / Previous 7 days / Older headings.
List<DrawerRow> groupedRows(List<ConversationInfo> chats, DateTime now) {
  final rows = <DrawerRow>[];
  ChatGroup? group;
  for (final c in chats) {
    final g = ChatGroup.of(c, now);
    if (g != group) {
      rows.add(DrawerHeading(g.label));
      group = g;
    }
    rows.add(DrawerChat(c));
  }
  return rows;
}

/// The chat drawer: new chat, search over titles and message text, the
/// chats by recency (paged in as the list scrolls), and Settings. A chat
/// whose reply is still generating shows a small spinner.
class ChatDrawer extends StatefulWidget {
  const ChatDrawer({super.key});

  @override
  State<ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<ChatDrawer> {
  final _scroll = ScrollController();
  final _query = TextEditingController();
  late final Services _s;

  @override
  void initState() {
    super.initState();
    _s = context.services;
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _s.chats.loadMore();
    });
  }

  @override
  void dispose() {
    // The drawer leaves the tree when it closes; a search ends with it.
    if (_s.chats.searching) _s.chats.search('');
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  void _close() => Scaffold.of(context).closeDrawer();

  void _newChat() {
    HapticFeedback.selectionClick();
    _s.sessions.startNew();
    _close();
  }

  void _open(ConversationInfo info) {
    HapticFeedback.selectionClick();
    _s.sessions.open(info);
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final width = math.min(MediaQuery.sizeOf(context).width * 0.86, 360.0);
    return Drawer(
      width: width,
      backgroundColor: c.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.smd,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  const AithraMark(size: 26),
                  const SizedBox(width: AppSpacing.smd - 2),
                  Expanded(
                    child: Text(
                      'Aithra',
                      style: AithraType.appBarTitle.copyWith(
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'New chat',
                    icon: const Icon(Icons.edit_square),
                    onPressed: _newChat,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.smd,
                0,
                AppSpacing.smd,
                AppSpacing.sm,
              ),
              child: _SearchField(controller: _query, onChanged: _search),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([_s.chats, _s.sessions]),
                builder: (context, _) => _list(context),
              ),
            ),
            Divider(height: 1, color: c.hairline),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                leading: Icon(Icons.settings_outlined, color: c.textSecondary),
                title: const Text('Settings'),
                onTap: () {
                  _close();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _search(String q) {
    _s.chats.search(q);
    setState(() {});
  }

  Widget _list(BuildContext context) {
    final chats = _s.chats;
    final items = chats.items;
    final current = _s.sessions.current.conversation?.id;
    if (items.isEmpty) {
      return _Empty(
        searching: _query.text.trim().isNotEmpty,
        loaded: chats.loaded,
      );
    }
    final rows = chats.searching
        ? [for (final c in items) DrawerChat(c)]
        : groupedRows(items, DateTime.now());
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        0,
        AppSpacing.sm,
        AppSpacing.md,
      ),
      itemCount: rows.length,
      itemBuilder: (context, i) => switch (rows[i]) {
        DrawerHeading(:final label) => _Heading(label, first: i == 0),
        DrawerChat(:final info) => _ChatRow(
          key: ValueKey(info.id),
          info: info,
          selected: info.id == current,
          replying: _s.sessions.replying(info.id),
          queued: _s.sessions.queued(info.id),
          match: chats.snippets[info.id],
          query: _query.text.trim(),
          onTap: () => _open(info),
        ),
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return SizedBox(
      height: 42,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: AithraType.body.copyWith(color: c.textPrimary),
        decoration: InputDecoration(
          hintText: 'Search chats',
          hintStyle: AithraType.body.copyWith(color: c.textTertiary),
          filled: true,
          fillColor: c.surfaceAlt,
          isDense: true,
          contentPadding: EdgeInsets.zero,
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 20,
            color: c.textTertiary,
          ),
          suffixIcon: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => controller.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear search',
                    iconSize: 18,
                    icon: Icon(Icons.close_rounded, color: c.textTertiary),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
            borderSide: BorderSide(color: c.accent.withValues(alpha: 0.5)),
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label, {required this.first});

  final String label;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.smd,
        first ? AppSpacing.sm : AppSpacing.mdl,
        AppSpacing.smd,
        AppSpacing.xs + 2,
      ),
      child: Text(
        label,
        style: AithraType.section.copyWith(color: c.textTertiary),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.searching, required this.loaded});

  final bool searching;
  final bool loaded;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    if (!loaded) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Text(
        searching
            ? 'No chats match.'
            : 'Your chats will appear here, encrypted on this phone.',
        textAlign: TextAlign.center,
        style: AithraType.bodySmall.copyWith(color: c.textTertiary),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.info,
    required this.selected,
    required this.replying,
    required this.queued,
    required this.query,
    required this.onTap,
    this.match,
    super.key,
  });

  final ConversationInfo info;
  final bool selected;

  /// The chat's reply is generating, or [queued] behind another chat's.
  final bool replying;
  final bool queued;

  /// While searching, the matching message and the words searched for.
  final String? match;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final match = this.match;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? c.surfaceAlt : Colors.transparent,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => _actions(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.smd,
              vertical: AppSpacing.smd - 2,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        info.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AithraType.label.copyWith(
                          color: c.textPrimary,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (match != null) ...[
                        const SizedBox(height: 2),
                        Text.rich(
                          _highlight(match, query, c),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AithraType.caption.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (replying) ...[
                  const SizedBox(width: AppSpacing.sm),
                  queued
                      ? Icon(
                          Icons.schedule_rounded,
                          size: 15,
                          color: c.textTertiary,
                          semanticLabel: 'Queued',
                        )
                      : Semantics(
                          label: 'Generating',
                          child: SizedBox.square(
                            dimension: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: c.accent,
                            ),
                          ),
                        ),
                ] else if (info.pinned) ...[
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
          ),
        ),
      ),
    );
  }

  /// [text] with each occurrence of [query] (ignoring case) emphasised.
  static TextSpan _highlight(String text, String query, SuiteColors c) {
    if (query.isEmpty) return TextSpan(text: text);
    final lower = text.toLowerCase();
    final needle = query.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    for (
      var at = lower.indexOf(needle);
      at >= 0;
      at = lower.indexOf(needle, at + needle.length)
    ) {
      spans
        ..add(TextSpan(text: text.substring(from, at)))
        ..add(
          TextSpan(
            text: text.substring(at, at + needle.length),
            style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w600),
          ),
        );
      from = at + needle.length;
    }
    spans.add(TextSpan(text: text.substring(from)));
    return TextSpan(children: spans);
  }

  Future<void> _actions(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final s = context.services;
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
        await s.chats.setPinned(info.id, !info.pinned);
      case 'rename':
        final title = await renameDialog(context, info.title);
        if (title != null && title.isNotEmpty) {
          await s.chats.rename(info.id, title);
        }
      case 'delete':
        if (await confirmDelete(context, info.title)) {
          await s.sessions.delete(info.id);
        }
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

/// Asks before deleting a chat, which cannot be undone.
Future<bool> confirmDelete(BuildContext context, String title) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          '"$title" and its photos will be deleted from this phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ==
    true;
