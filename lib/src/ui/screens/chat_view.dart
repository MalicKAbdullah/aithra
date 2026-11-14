import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_models.dart';
import '../../chat/chat_session.dart';
import '../../docs/documents.dart';
import '../../memory/profile.dart';
import '../../quick_actions.dart';
import '../../services.dart';
import '../aithra_type.dart';
import '../widgets/composer.dart';
import '../widgets/file_chip.dart';
import '../widgets/composer_attach.dart';
import '../widgets/find_bar.dart';
import '../widgets/greeting.dart';
import '../widgets/message_bubble.dart';
import '../widgets/perf_hud.dart';
import '../widgets/prompt_shortcut_chips.dart';
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
  late final QuickActions _quickActions;

  ChatSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_takeReveal);
    _session.finding.addListener(_findToggled);
    _composer.text.text = _session.conversation?.draft ?? '';
    _composer.text.addListener(_onDraftChanged);
    _composer.summarise = _summarise;
    _session.incoming.addListener(_takeIncoming);
    _takeIncoming();
    _scroll.addListener(() {
      // Reversed list: extentAfter is the distance to the oldest loaded message.
      if (_scroll.position.extentAfter < 800) _session.loadMore();
    });
    _quickActions = context.services.quickActions..addListener(_onQuickAction);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onQuickAction());
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

  /// Fills the composer with what was shared from another app.
  void _takeIncoming() {
    final item = _session.incoming.value;
    if (item == null) return;
    _session.incoming.value = null;
    if (item.text.isNotEmpty) {
      _composer.text.text = item.text;
      _composer.shared.value = true;
    }
    _composer.images.value = [
      ..._composer.images.value,
      for (final jpeg in item.images) PendingImage(jpeg),
    ];
    _composer.docs.value = [..._composer.docs.value, ...item.documents];
  }

  /// Sends [docs] with a request for their summary, which the summarizer
  /// posts as the reply.
  Future<void> _summarise(List<DocInfo> docs) async {
    final summarizer = context.services.summarizer;
    _composer.clear();
    await _session.send(
      docs.length == 1
          ? 'Summarise ${docs.single.name}'
          : 'Summarise these documents',
      const [],
      docs: docs,
      reply: false,
    );
    final sent = _session.messages.firstOrNull;
    for (final d in _session.attachments[sent?.id] ?? const <DocInfo>[]) {
      unawaited(summarizer.summarize(d));
    }
  }

  /// "Ask about a photo" opened this new chat to pick the photo in it.
  void _onQuickAction() {
    final s = context.services;
    if (!mounted || !identical(s.sessions.current, _session)) return;
    if (s.quickActions.takePhotoRequest()) {
      showAttachMenu(context, _composer);
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
    _quickActions.removeListener(_onQuickAction);
    _session.removeListener(_takeReveal);
    _session.finding.removeListener(_findToggled);
    _reveal.dispose();
    _draftTimer?.cancel();
    _session.incoming.removeListener(_takeIncoming);
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
    final docs = List.of(_composer.docs.value);
    if (text.trim().isEmpty && images.isEmpty && docs.isEmpty) return;
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
    final sending = _session.send(text, images, docs: docs);
    _readReplyAloud();
    await sending;
  }

  void _readReplyAloud() {
    final s = context.services;
    if (s.settings.speakReplies) s.readAloud.followReply(_session);
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
            _ActivityLine(_session.activity),
            RepaintBoundary(
              child: ListenableBuilder(
                listenable: Listenable.merge([_session, s.assistant]),
                builder: (context, _) => Composer(
                  controller: _composer,
                  speech: s.speech,
                  busy: _session.busy,
                  onSend: () {
                    if (_composer.editing) {
                      final text = _composer.text.text;
                      _composer.clear();
                      _session.editLast(text);
                      _readReplyAloud();
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
          ? Greeting(
              now: _greetedAt,
              below: PromptShortcutChips(
                onPick: (p) {
                  _composer.setText(p.prompt);
                  _composer.focus.requestFocus();
                },
              ),
            )
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
        final remembered = _session.memoryUpdates[m.seq];
        final files = _session.attachments[m.id];
        final sources = _session.sources[m.id];
        final cutOff = _session.canContinue(m);
        if (notice == null &&
            remembered == null &&
            !cutOff &&
            files == null &&
            sources == null) {
          return RevealAnchor(controller: _reveal, seq: m.seq, child: bubble);
        }
        return RevealAnchor(
          key: ValueKey('after-${m.seq}'),
          controller: _reveal,
          seq: m.seq,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bubble,
              if (files != null) MessageFiles(docs: files),
              if (sources != null) SourcesRow(sources: sources),
              if (cutOff) _ContinueRow(onContinue: _session.continueReply),
              if (remembered != null)
                _MemoryHint(
                  update: remembered,
                  onUndone: () =>
                      setState(() => _session.memoryUpdates.remove(m.seq)),
                ),
              if (notice != null) _NoticeRow(notice),
            ],
          ),
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

/// What the reply is doing before it streams, above the composer: "Reading
/// report.pdf, page 2 (2 of 5)".
class _ActivityLine extends StatelessWidget {
  const _ActivityLine(this.activity);

  final ValueListenable<String?> activity;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return ValueListenableBuilder<String?>(
      valueListenable: activity,
      builder: (context, text, _) => AnimatedSize(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        child: text == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.xs,
                  AppSpacing.gutter,
                  AppSpacing.xs,
                ),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.textTertiary,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AithraType.caption.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
