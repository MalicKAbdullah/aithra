import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_models.dart';
import '../../chat/chat_session.dart';
import '../../services.dart';
import '../aithra_type.dart';
import '../widgets/composer.dart';
import '../widgets/greeting.dart';
import '../widgets/message_bubble.dart';
import '../widgets/perf_hud.dart';
import 'memories_screen.dart';
import 'models_screen.dart';

/// One chat on the home screen: its messages, the reply in progress and the
/// composer. The session it shows belongs to ChatSessions, so leaving this
/// view never stops a reply; the view only keeps the composer draft and the
/// scroll position.
class ChatView extends StatefulWidget {
  const ChatView({required this.session, super.key});

  final ChatSession session;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scroll = ScrollController();
  final _composer = ComposerController();
  final _greetedAt = DateTime.now();
  Timer? _draftTimer;

  ChatSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _composer.text.text = _session.conversation?.draft ?? '';
    _composer.text.addListener(_onDraftChanged);
    _scroll.addListener(() {
      // Reversed list: extentAfter is the distance to the oldest loaded message.
      if (_scroll.position.extentAfter < 800) _session.loadMore();
    });
    // A session still held for its reply already has its messages and the
    // reader's place in them is the newest end.
    if (_session.messages.isEmpty) {
      _session.loadMore().then((_) {
        final offset = _session.conversation?.scroll ?? 0;
        if (offset > 0 && _scroll.hasClients) {
          _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
        }
      });
    }
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
    }
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
        // The stored text: Markdown and LaTeX source, as the model wrote it.
        await Clipboard.setData(ClipboardData(text: m.content));
        _toast('Copied');
      case 'share':
        await s.native.shareText(m.content);
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

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: _session,
                builder: (context, _) => _messagesList(context),
              ),
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
    );
  }

  Widget _messagesList(BuildContext context) {
    final messages = _session.messages;
    final extra = (_session.busy ? 1 : 0) + (_session.error != null ? 1 : 0);
    if (messages.isEmpty && extra == 0) {
      return _session.conversation == null
          ? Greeting(now: _greetedAt)
          : const SizedBox.shrink();
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
        final bubble = MessageBubble(
          key: ValueKey(m.seq),
          message: m,
          onLongPress: () => _messageActions(m),
        );
        final notice = _session.notices[m.seq];
        final remembered = _session.memoryUpdates.contains(m.seq);
        if (notice == null && !remembered) return bubble;
        return Column(
          key: ValueKey('after-${m.seq}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            bubble,
            if (remembered) const _MemoryHint(),
            if (notice != null) _NoticeRow(notice),
          ],
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
}

/// A quiet line under a reply after which Aithra updated its memory of the
/// user; it fades in and never asks for anything. Tap to see what Aithra
/// remembers.
class _MemoryHint extends StatelessWidget {
  const _MemoryHint();

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.slow,
      curve: AppMotion.standard,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: InkWell(
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const MemoriesScreen())),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            2,
            AppSpacing.gutter,
            AppSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 14,
                color: c.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                'Memory updated',
                style: AithraType.caption.copyWith(color: c.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet line under a reply saying something did not work for it; tap
/// for the details and what to do.
class _NoticeRow extends StatelessWidget {
  const _NoticeRow(this.notice);

  final ReplyNotice notice;

  Future<void> _details(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    builder: (sheet) {
      final c = SuiteColors.of(sheet);
      final s = context.services;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.lg,
            AppSpacing.gutter,
            AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                notice.title,
                style: AithraType.h2.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                notice.details,
                style: AithraType.body.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (notice.recall) ...[
                    TextButton(
                      onPressed: () {
                        Navigator.pop(sheet);
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ModelsScreen(),
                          ),
                        );
                      },
                      child: const Text('Models'),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton(
                      onPressed: () {
                        s.recall.retry();
                        Navigator.pop(sheet);
                      },
                      child: const Text('Try again'),
                    ),
                  ] else
                    FilledButton(
                      onPressed: () => Navigator.pop(sheet),
                      child: const Text('OK'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return InkWell(
      onTap: () => _details(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          2,
          AppSpacing.gutter,
          AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 14, color: c.warning),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '${notice.title} · tap for details',
                style: AithraType.caption.copyWith(color: c.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
