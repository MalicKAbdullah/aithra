import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../../chat/chat_session.dart';
import '../../memory/profile.dart';
import '../../services.dart';
import '../aithra_type.dart';
import '../widgets/composer.dart';
import '../widgets/find_bar.dart';
import '../widgets/greeting.dart';
import '../widgets/message_actions.dart';
import '../widgets/message_bubble.dart';
import '../widgets/perf_hud.dart';
import '../widgets/reveal.dart';
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
  final _reveal = RevealController();
  Timer? _draftTimer;

  /// The user message being rewritten in the composer.
  ChatMessage? _editing;

  /// The user message whose actions are showing, by seq.
  int? _actionsFor;

  ChatSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_takeReveal);
    _session.finding.addListener(_findToggled);
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
        _takeReveal();
      });
    } else {
      _takeReveal();
    }
  }

  /// Shows the message a search asked for (see [ChatSession.reveal]).
  void _takeReveal() {
    final seq = _session.takeReveal();
    if (seq != null) unawaited(_show(seq));
  }

  Future<void> _show(int seq) async {
    await _session.loadThrough(seq);
    // The loaded page is laid out before the list can scroll into it.
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) await _reveal.reveal(seq, _scroll);
  }

  void _findToggled() {
    if (!_session.finding.value) _reveal.clear();
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
    _session.removeListener(_takeReveal);
    _session.finding.removeListener(_findToggled);
    _reveal.dispose();
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

  /// Puts [m] in the composer; sending replaces it and everything after.
  void _edit(ChatMessage m) {
    _composer.text.text = m.content;
    _composer.editing = true;
    _composer.focus.requestFocus();
    setState(() {
      _editing = m;
      _actionsFor = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return Stack(
      children: [
        Column(
          children: [
            ValueListenableBuilder(
              valueListenable: _session.finding,
              builder: (context, open, _) => open
                  ? FindBar(session: _session, onShow: _show)
                  : const SizedBox.shrink(),
            ),
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
                    final editing = _editing;
                    if (_composer.editing && editing != null) {
                      final text = _composer.text.text;
                      _composer.clear();
                      _editing = null;
                      _session.edit(editing, text);
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
    final hasError = _session.error != null;
    final busy = _session.busy;
    if (messages.isEmpty && !busy && !hasError) {
      return _session.conversation == null
          ? Greeting(now: _greetedAt)
          : const SizedBox.shrink();
    }
    final newest = messages.firstOrNull;
    // A reply is saved under the next seq of its chat (the store appends at
    // its highest seq + 1), so the reply in progress takes the key it will
    // have once saved and keeps its element, laid-out text and all.
    final streamingSeq = newest != null && newest.seq >= 0
        ? newest.seq + 1
        : null;
    // The newest item has a sliver of its own (see SliverKeepReadingPlace);
    // the rest follow in a lazy list.
    final older = busy ? messages : messages.skip(1).toList();
    final index = {for (final (i, m) in older.indexed) ValueKey(m.seq): i};
    return SelectionArea(
      child: CustomScrollView(
        controller: _scroll,
        reverse: true,
        slivers: [
          if (hasError) SliverToBoxAdapter(child: _errorRow(context)),
          if (busy || newest != null)
            SliverKeepReadingPlace(
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: busy
                    ? RevealAnchor(
                        key: streamingSeq == null
                            ? const ValueKey('reply')
                            : ValueKey(streamingSeq),
                        controller: _reveal,
                        seq: streamingSeq ?? -1,
                        child: ModelTurn(session: _session),
                      )
                    : _item(newest!, newest),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            sliver: SliverList.builder(
              itemCount: older.length,
              findChildIndexCallback: (key) => index[key],
              itemBuilder: (context, i) => _item(older[i], newest),
            ),
          ),
        ],
      ),
    );
  }

  /// A saved message, anchored for search (see [RevealController]) under
  /// its seq; the reply in progress is anchored the same way, so it keeps
  /// its element once saved.
  Widget _item(ChatMessage m, ChatMessage? newest) => RevealAnchor(
    key: ValueKey(m.seq),
    controller: _reveal,
    seq: m.seq,
    child: _message(m, newest),
  );

  Widget _message(ChatMessage m, ChatMessage? newest) {
    final busy = _session.busy;
    if (m.role == Role.user) {
      return MessageBubble(
        message: m,
        onTap: () =>
            setState(() => _actionsFor = _actionsFor == m.seq ? null : m.seq),
        footer: [
          if (_actionsFor == m.seq)
            UserActions(
              message: m,
              session: _session,
              onEdit: busy ? null : () => _edit(m),
            ),
        ],
      );
    }
    final notice = _session.notices[m.seq];
    return ModelTurn(
      session: _session,
      message: m,
      footer: [
        ReplyActions(
          message: m,
          session: _session,
          canRegenerate: identical(m, newest),
        ),
        if (_session.canContinue(m))
          _ContinueRow(onContinue: _session.continueReply),
        if (_session.memoryUpdates[m.seq] case final update?)
          _MemoryHint(
            update: update,
            onUndone: () =>
                setState(() => _session.memoryUpdates.remove(m.seq)),
          ),
        if (notice != null) _NoticeRow(notice),
      ],
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

/// Under a reply that stopped at the reply length limit: writes the rest
/// onto it.
class _ContinueRow extends StatelessWidget {
  const _ContinueRow({required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              'Reply reached its length limit',
              style: AithraType.caption.copyWith(color: c.textTertiary),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          TextButton.icon(
            onPressed: onContinue,
            icon: const Icon(Icons.arrow_forward_rounded, size: 18),
            label: const Text('Continue'),
          ),
        ],
      ),
    );
  }
}

/// A quiet line under a reply after which Aithra updated the user's
/// profile; it fades in and never asks for anything. Tap to see what Aithra
/// remembers, or Undo to put the section back as it was.
class _MemoryHint extends StatelessWidget {
  const _MemoryHint({required this.update, required this.onUndone});

  final MemoryUpdate update;
  final VoidCallback onUndone;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final memories = context.services.memories;
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
              ListenableBuilder(
                listenable: memories,
                builder: (context, _) => memories.canUndo(update)
                    ? TextButton(
                        onPressed: () async {
                          if (await memories.undo(update)) onUndone();
                        },
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 40),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                          ),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: AithraType.caption.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: const Text('Undo'),
                      )
                    : const SizedBox.shrink(),
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
