import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_models.dart';
import '../../chat/chat_session.dart';
import '../../chat/markdown.dart';
import '../../memory/memory_keeper.dart';
import '../../services.dart';
import '../../voice/sentence_splitter.dart';
import '../aithra_type.dart';

/// Copies a reply as readable plain text, with HTML alongside so apps that
/// take formatting paste its headings, lists and tables.
Future<void> copyReply(BuildContext context, String source) async {
  final messenger = ScaffoldMessenger.of(context);
  await context.services.native.copy(
    plainText(source),
    html: markdownHtml(source),
  );
  unawaited(HapticFeedback.selectionClick());
  messenger.showSnackBar(const SnackBar(content: Text('Copied')));
}

Future<void> _copyText(BuildContext context, String text, String done) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  unawaited(HapticFeedback.selectionClick());
  messenger.showSnackBar(SnackBar(content: Text(done)));
}

/// A compact icon button for the rows under messages: 36 dp square, quiet
/// until pressed.
class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 18,
      color: color ?? c.textTertiary,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// The row under each finished reply: Copy, Read aloud, Regenerate (on the
/// newest reply), Share and More, with a ‹2/3› pager once the reply has been
/// regenerated.
class ReplyActions extends StatelessWidget {
  const ReplyActions({
    required this.message,
    required this.session,
    required this.canRegenerate,
    super.key,
  });

  final ChatMessage message;
  final ChatSession session;
  final bool canRegenerate;

  /// The reply being read aloud, by seq; one at a time across the app.
  static final speaking = ValueNotifier<int?>(null);

  Future<void> _readAloud(BuildContext context) async {
    final tts = context.services.tts;
    final seq = message.seq;
    if (speaking.value == seq) {
      speaking.value = null;
      await tts.stop();
      return;
    }
    await tts.stop();
    speaking.value = seq;
    final splitter = SentenceSplitter();
    final sentences = [
      ...splitter.add(spokenText(message.content)),
      ...splitter.flush(),
    ];
    for (final s in sentences) {
      if (speaking.value != seq) return;
      await tts.say(s);
    }
    await tts.idle;
    if (speaking.value == seq) speaking.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final versions = session.versionsOf(message);
    final busy = session.busy;
    return Transform.translate(
      // The first icon's glyph lines up with the reply's text.
      offset: const Offset(-9, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (versions != null) ...[
            _ActionIcon(
              icon: Icons.chevron_left_rounded,
              label: 'Previous answer',
              onPressed: busy || versions.shown == 0
                  ? null
                  : () => session.showVersion(message, versions.shown - 1),
            ),
            Text(
              '${versions.shown + 1}/${versions.versions.length}',
              style: AithraType.caption.copyWith(
                color: c.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            _ActionIcon(
              icon: Icons.chevron_right_rounded,
              label: 'Next answer',
              onPressed: busy || versions.shown == versions.versions.length - 1
                  ? null
                  : () => session.showVersion(message, versions.shown + 1),
            ),
          ],
          _ActionIcon(
            icon: Icons.content_copy_rounded,
            label: 'Copy',
            onPressed: () => copyReply(context, message.content),
          ),
          ValueListenableBuilder<int?>(
            valueListenable: speaking,
            builder: (context, seq, _) => seq == message.seq
                ? _ActionIcon(
                    icon: Icons.stop_circle_outlined,
                    label: 'Stop reading',
                    color: c.accent,
                    onPressed: () => _readAloud(context),
                  )
                : _ActionIcon(
                    icon: Icons.volume_up_outlined,
                    label: 'Read aloud',
                    onPressed: () => _readAloud(context),
                  ),
          ),
          if (canRegenerate)
            _ActionIcon(
              icon: Icons.refresh_rounded,
              label: 'Regenerate',
              onPressed: busy ? null : session.regenerate,
            ),
          _ActionIcon(
            icon: Icons.ios_share_rounded,
            label: 'Share',
            onPressed: () =>
                context.services.native.shareText(plainText(message.content)),
          ),
          _ActionIcon(
            icon: Icons.more_horiz_rounded,
            label: 'More',
            onPressed: () => _more(context),
          ),
        ],
      ),
    );
  }

  Future<void> _more(BuildContext context) async {
    final stats = message.stats;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetItem(
              sheet,
              Icons.code_rounded,
              'Copy as Markdown',
              'markdown',
            ),
            _sheetItem(
              sheet,
              Icons.notes_rounded,
              'View as plain text',
              'plain',
            ),
            if (stats?.decodeTps != null)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(
                  '${stats!.decodeTps!.toStringAsFixed(1)} tokens/s · '
                  'first word after '
                  '${((stats.ttftMs ?? 0) / 1000).toStringAsFixed(1)} s',
                  style: AithraType.caption.copyWith(
                    color: SuiteColors.of(sheet).textTertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'markdown':
        await _copyText(context, message.content, 'Markdown copied');
      case 'plain':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PlainTextPage(text: message.content),
          ),
        );
    }
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

/// The row a tap on a user message reveals: Copy, Edit, Remember this
/// (while memory is on for the chat) and Share.
class UserActions extends StatelessWidget {
  const UserActions({
    required this.message,
    required this.session,
    required this.onEdit,
    super.key,
  });

  final ChatMessage message;
  final ChatSession session;

  /// Null while a reply is running, since editing restarts the chat there.
  final VoidCallback? onEdit;

  Future<void> _remember(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final memories = context.services.memories;
    final result = await context.services.keeper.rememberExplicit(
      message.content,
    );
    unawaited(HapticFeedback.selectionClick());
    messenger.showSnackBar(switch (result) {
      Remembered(:final update) => SnackBar(
        content: const Text('Aithra will remember this'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => memories.undo(update),
        ),
      ),
      AlreadyRemembered() => const SnackBar(
        content: Text('Aithra already remembers this'),
      ),
      RememberLater() => const SnackBar(
        content: Text('Aithra will remember this once the model is free'),
      ),
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final hasText = message.content.isNotEmpty;
    return Transform.translate(
      offset: const Offset(9, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasText)
            _ActionIcon(
              icon: Icons.content_copy_rounded,
              label: 'Copy',
              onPressed: () => _copyText(context, message.content, 'Copied'),
            ),
          _ActionIcon(
            icon: Icons.edit_outlined,
            label: 'Edit',
            onPressed: onEdit,
          ),
          if (hasText && s.settings.memoryEnabled && !session.skipMemory)
            _ActionIcon(
              icon: Icons.bookmark_add_outlined,
              label: 'Remember this',
              onPressed: () => _remember(context),
            ),
          if (hasText)
            _ActionIcon(
              icon: Icons.ios_share_rounded,
              label: 'Share',
              onPressed: () => s.native.shareText(message.content),
            ),
        ],
      ),
    );
  }
}

/// A message exactly as written, Markdown and LaTeX source included, for
/// reading or selecting when the formatted view gets in the way.
class PlainTextPage extends StatelessWidget {
  const PlainTextPage({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plain text'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.content_copy_rounded),
            onPressed: () => _copyText(context, text, 'Copied'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          AppSpacing.xl,
        ),
        child: SelectableText(
          text,
          style: AithraType.code.copyWith(
            color: c.textPrimary,
            fontSize: 13.5,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
