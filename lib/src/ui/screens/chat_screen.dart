import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_models.dart';
import '../../chat/chat_session.dart';
import '../../services.dart';
import '../aithra_type.dart';
import '../widgets/aithra_mark.dart';
import '../widgets/composer.dart';
import '../widgets/message_bubble.dart';
import '../widgets/perf_hud.dart';
import 'home_screen.dart' show renameDialog;

class ChatScreen extends StatefulWidget {
  const ChatScreen({this.conversation, super.key});

  final ConversationInfo? conversation;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final Services _s;
  late final ChatSession _session;
  final _scroll = ScrollController();
  final _composer = ComposerController();
  Timer? _draftTimer;

  @override
  void initState() {
    super.initState();
    final s = _s = context.services;
    _session = ChatSession(
      native: s.native,
      assistant: s.assistant,
      store: s.chats,
      memories: s.memories,
      conversation: widget.conversation,
    );
    _composer.text.text = widget.conversation?.draft ?? '';
    _composer.text.addListener(_onDraftChanged);
    _scroll.addListener(() {
      // Reversed list: extentAfter is the distance to the oldest loaded message.
      if (_scroll.position.extentAfter < 800) _session.loadMore();
    });
    _session.loadMore().then((_) {
      final offset = widget.conversation?.scroll ?? 0;
      if (offset > 0 && _scroll.hasClients) {
        _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
      }
    });
    s.assistant.warmUp();
  }

  void _onDraftChanged() {
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 600),
      () => _session.saveDraft(_composer.text.text),
    );
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (_session.conversation != null) {
      _session.saveDraft(_composer.text.text);
      if (_scroll.hasClients) _session.saveScroll(_scroll.offset);
      _s.chats.upsert(_session.conversation!.id);
    }
    _session.dispose();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _composer.text.text;
    final images = List.of(_composer.images.value);
    if (text.trim().isEmpty && images.isEmpty) return;
    _composer.clear();
    if (_scroll.hasClients && _scroll.offset > 0) {
      unawaited(
        _scroll.animateTo(
          0,
          duration: AppMotion.base,
          curve: AppMotion.emphasized,
        ),
      );
    }
    await _session.send(text, images);
  }

  Future<void> _messageActions(ChatMessage m) async {
    HapticFeedback.mediumImpact();
    final s = context.services;
    final lastUser = _session.messages
        .where((x) => x.role == Role.user)
        .firstOrNull;
    final isLastModel =
        _session.messages.isNotEmpty &&
        _session.messages.first.id == m.id &&
        m.role == Role.model;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetItem(context, Icons.content_copy_rounded, 'Copy', 'copy'),
            _sheetItem(context, Icons.ios_share_rounded, 'Share', 'share'),
            _sheetItem(
              context,
              Icons.bookmark_add_outlined,
              'Remember this',
              'remember',
            ),
            if (m.role == Role.user && lastUser?.id == m.id && !_session.busy)
              _sheetItem(context, Icons.edit_outlined, 'Edit', 'edit'),
            if (isLastModel && !_session.busy)
              _sheetItem(
                context,
                Icons.refresh_rounded,
                'Regenerate',
                'regenerate',
              ),
            if (m.stats?.decodeTps != null)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(
                  '${m.stats!.decodeTps!.toStringAsFixed(1)} tokens/s · '
                  'first word after ${((m.stats!.ttftMs ?? 0) / 1000).toStringAsFixed(1)} s',
                  style: AithraType.caption.copyWith(
                    color: SuiteColors.of(context).textTertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.content));
        _toast('Copied');
      case 'share':
        await s.native.shareText(m.content);
      case 'remember':
        await s.memories.add(
          m.content.length > 300
              ? '${m.content.substring(0, 300)}…'
              : m.content,
        );
        _toast('Saved to memories');
      case 'edit':
        _composer.text.text = m.content;
        _composer.editing = true;
        _composer.focus.requestFocus();
        setState(() {});
      case 'regenerate':
        await _session.regenerate();
    }
  }

  Widget _sheetItem(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    onTap: () => Navigator.pop(context, value),
  );

  void _toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _menu(String action) async {
    final s = context.services;
    final conv = _session.conversation;
    if (conv == null) return;
    switch (action) {
      case 'rename':
        final title = await renameDialog(context, conv.title);
        if (title != null && title.isNotEmpty) {
          await s.chats.rename(conv.id, title);
          setState(() {});
        }
      case 'delete':
        await s.chats.delete(conv.id);
        if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: ListenableBuilder(
          listenable: Listenable.merge([_session, s.chats, s.engine]),
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.chats.items
                        .where((x) => x.id == _session.conversation?.id)
                        .firstOrNull
                        ?.title ??
                    _session.conversation?.title ??
                    'New chat',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AithraType.chatTitle.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: 1),
              Text(
                _modelLine(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AithraType.caption.copyWith(color: c.textTertiary),
              ),
            ],
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'delete', child: Text('Delete chat')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: ListenableBuilder(
                  listenable: _session,
                  builder: (context, _) => _messagesList(context),
                ),
              ),
              ListenableBuilder(
                listenable: Listenable.merge([_session, s.memories]),
                builder: (context, _) => _suggestions(context),
              ),
              RepaintBoundary(
                child: ListenableBuilder(
                  listenable: Listenable.merge([_session, s.assistant]),
                  builder: (context, _) => Composer(
                    controller: _composer,
                    busy: _session.busy,
                    canAttachImages: s.assistant.activeModel?.vision ?? false,
                    onSend: () {
                      if (_composer.editing) {
                        final text = _composer.text.text;
                        _composer.clear();
                        _session.editLast(text);
                      } else {
                        _send();
                      }
                    },
                    onStop: _session.stop,
                    onFocus: s.assistant.warmUp,
                  ),
                ),
              ),
            ],
          ),
          const PerfHud(),
        ],
      ),
    );
  }

  String _modelLine(BuildContext context) {
    final a = context.services.assistant;
    final m = a.activeModel;
    if (m == null) return 'No model';
    final b = a.backendFor(m);
    return b == null ? m.name : '${m.name} · ${b.label}';
  }

  Widget _messagesList(BuildContext context) {
    final c = SuiteColors.of(context);
    final messages = _session.messages;
    final extra = (_session.busy ? 1 : 0) + (_session.error != null ? 1 : 0);
    if (messages.isEmpty && extra == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AithraMark(size: 48),
              const SizedBox(height: AppSpacing.md),
              Text(
                'How can I help?',
                style: AithraType.h1.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Everything stays on this phone.',
                style: AithraType.bodySmall.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: messages.length + extra,
      itemBuilder: (context, i) {
        if (_session.error != null && i == 0) return _errorRow(context);
        final offset = _session.error != null ? 1 : 0;
        if (_session.busy && i == offset) {
          return StreamingBubble(
            key: const ValueKey('streaming'),
            session: _session,
          );
        }
        final m = messages[i - extra];
        return MessageBubble(
          key: ValueKey(m.seq),
          message: m,
          onLongPress: () => _messageActions(m),
        );
      },
    );
  }

  Widget _errorRow(BuildContext context) {
    final c = SuiteColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.gutter,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: c.negative, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              _session.error!,
              style: AithraType.bodySmall.copyWith(color: c.negative),
            ),
          ),
          TextButton(onPressed: _session.retry, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _suggestions(BuildContext context) {
    final s = context.services;
    final items = s.memories.filterSuggestions(_session.suggestions);
    if (items.isEmpty) return const SizedBox.shrink();
    final c = SuiteColors.of(context);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        children: [
          for (final f in items)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: InputChip(
                avatar: Icon(
                  Icons.bookmark_add_outlined,
                  size: 18,
                  color: c.accent,
                ),
                label: Text('Remember: $f'),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  s.memories.add(f);
                },
                onDeleted: () => s.memories.dismiss(f),
              ),
            ),
        ],
      ),
    );
  }
}
