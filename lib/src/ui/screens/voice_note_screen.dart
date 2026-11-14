import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services.dart';
import '../../voice/dictation.dart';
import '../../voice/voice_note.dart';
import '../aithra_type.dart';
import '../widgets/markdown_view.dart';
import '../widgets/recording_bar.dart';
import '../widgets/speech_notice.dart';

/// Dictate a note, then have Aithra clean it up, summarise it or pull out
/// its action items, or keep it as a chat. Nothing is recorded as audio:
/// only the recognised text is kept.
class VoiceNoteScreen extends StatefulWidget {
  const VoiceNoteScreen({super.key});

  @override
  State<VoiceNoteScreen> createState() => _VoiceNoteScreenState();
}

class _VoiceNoteScreenState extends State<VoiceNoteScreen>
    with SingleTickerProviderStateMixin {
  late final Services _s = context.services;
  late final Dictation _dictation = Dictation(_s.speech)
    ..onEnd = _onDictationEnd;
  late final VoiceNoteRunner _runner = VoiceNoteRunner(_s.assistant);

  /// The note so far: what earlier recordings committed.
  String _note = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _s.assistant.warmUp();
    WidgetsBinding.instance.addPostFrameCallback((_) => _record());
  }

  @override
  void dispose() {
    _dictation.dispose();
    _runner.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    await _runner.stop();
    await _dictation.start();
  }

  void _onDictationEnd(DictationEnd end, String committed) {
    if (!mounted) return;
    switch (end) {
      case DictationEnd.cancelled:
        // Cancel on the first recording discards the note.
        if (_note.isEmpty) Navigator.of(context).maybePop();
      case DictationEnd.failed:
        showSpeechProblem(context, _s.speech);
        _note = joinSpeech(_note, committed);
      case DictationEnd.done:
        _note = joinSpeech(_note, committed);
    }
    setState(() {});
  }

  Future<void> _run(NoteAction action) async {
    HapticFeedback.selectionClick();
    await _runner.run(action, _note);
  }

  Future<void> _saveAsChat() async {
    if (_saving) return;
    setState(() => _saving = true);
    await _runner.stop();
    final info = await saveNoteAsChat(
      native: _s.native,
      chats: _s.chats,
      note: _note,
      result: _runner.result,
    );
    _s.sessions.open(info);
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Voice note')),
      body: SafeArea(
        child: ValueListenableBuilder<DictationPhase>(
          valueListenable: _dictation.phase,
          builder: (context, phase, _) {
            final recording = phase != DictationPhase.idle;
            return Column(
              children: [
                Expanded(
                  child: recording
                      ? _Recording(note: _note, dictation: _dictation)
                      : _Result(note: _note, runner: _runner, onCopy: _copy),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.sm,
                    AppSpacing.xs,
                    AppSpacing.sm,
                    AppSpacing.sm,
                  ),
                  child: recording
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            color: c.surfaceAlt,
                            borderRadius: BorderRadius.circular(
                              AppSpacing.radiusXl,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(composerInset),
                            child: Theme(
                              data: Theme.of(context).copyWith(
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: RecordingBar(
                                dictation: _dictation,
                                onCancel: _dictation.cancel,
                                onDone: _dictation.finish,
                              ),
                            ),
                          ),
                        )
                      : _Actions(
                          runner: _runner,
                          hasNote: _note.trim().isNotEmpty,
                          saving: _saving,
                          onRun: _run,
                          onRecord: _record,
                          onSave: _saveAsChat,
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The note as it is dictated, in a large readable size, newest at the
/// bottom.
class _Recording extends StatelessWidget {
  const _Recording({required this.note, required this.dictation});

  final String note;
  final Dictation dictation;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final style = AithraType.body.copyWith(fontSize: 19, height: 1.5);
    return ListenableBuilder(
      listenable: Listenable.merge([dictation.committed, dictation.partial]),
      builder: (context, _) {
        final committed = joinSpeech(note, dictation.committed.value);
        final partial = dictation.partial.value;
        return SingleChildScrollView(
          reverse: true,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.md,
            AppSpacing.gutter,
            AppSpacing.lg,
          ),
          child: SizedBox(
            width: double.infinity,
            child: Text.rich(
              committed.isEmpty && partial.isEmpty
                  ? TextSpan(
                      text: 'Start speaking. Your words appear here.',
                      style: TextStyle(color: c.textTertiary),
                    )
                  : TextSpan(
                      children: [
                        TextSpan(
                          text: committed,
                          style: TextStyle(color: c.textPrimary),
                        ),
                        if (partial.isNotEmpty)
                          TextSpan(
                            text: committed.isEmpty ? partial : ' $partial',
                            style: TextStyle(color: c.textSecondary),
                          ),
                      ],
                    ),
              style: style,
            ),
          ),
        );
      },
    );
  }
}

/// The finished note and, once one ran, the model's result under it.
class _Result extends StatelessWidget {
  const _Result({
    required this.note,
    required this.runner,
    required this.onCopy,
  });

  final String note;
  final VoiceNoteRunner runner;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return ListenableBuilder(
      listenable: runner,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          AppSpacing.lg,
        ),
        children: [
          _Heading(
            'Your note',
            onCopy: note.isEmpty ? null : () => onCopy(note),
          ),
          if (note.isEmpty)
            Text(
              'Nothing was heard. Record again when you are ready.',
              style: AithraType.body.copyWith(color: c.textTertiary),
            )
          else
            SelectableText(
              note,
              style: AithraType.body.copyWith(color: c.textPrimary),
            ),
          if (runner.action case final action?) ...[
            const SizedBox(height: AppSpacing.lg),
            _Heading(
              action.heading,
              onCopy: runner.result == null
                  ? null
                  : () => onCopy(runner.result!),
            ),
            if (runner.error case final error?)
              Text(
                error,
                style: AithraType.bodySmall.copyWith(color: c.negative),
              )
            else
              ValueListenableBuilder<String>(
                valueListenable: runner.output,
                builder: (context, text, _) => text.isEmpty && runner.running
                    ? Text(
                        'Thinking…',
                        style: AithraType.body.copyWith(color: c.textTertiary),
                      )
                    : MarkdownView(runner.result ?? text),
              ),
          ],
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, {this.onCopy});

  final String title;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: AithraType.section.copyWith(color: c.textSecondary),
            ),
          ),
          if (onCopy != null)
            IconButton(
              tooltip: 'Copy',
              iconSize: 18,
              color: c.textTertiary,
              icon: const Icon(Icons.content_copy_rounded),
              onPressed: onCopy,
            ),
        ],
      ),
    );
  }
}

/// The chips that act on the note, and Record more / Save as chat.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.runner,
    required this.hasNote,
    required this.saving,
    required this.onRun,
    required this.onRecord,
    required this.onSave,
  });

  final VoiceNoteRunner runner;
  final bool hasNote;
  final bool saving;
  final ValueChanged<NoteAction> onRun;
  final VoidCallback onRecord;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return ListenableBuilder(
      listenable: runner,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.smd),
            child: Row(
              children: [
                for (final a in NoteAction.values) ...[
                  ChoiceChip(
                    label: Text(a.label),
                    labelStyle: AithraType.label.copyWith(
                      color: runner.action == a ? c.onAccent : c.textPrimary,
                    ),
                    selected: runner.action == a,
                    selectedColor: c.accent,
                    backgroundColor: c.surface,
                    showCheckmark: false,
                    side: BorderSide(
                      color: runner.action == a ? c.accent : c.border,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        AppSpacing.radiusPill,
                      ),
                    ),
                    onSelected: !hasNote || runner.running && runner.action == a
                        ? null
                        : (_) => onRun(a),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: runner.running ? runner.stop : onRecord,
                    icon: Icon(
                      runner.running ? Icons.stop_rounded : Icons.mic_rounded,
                      size: 20,
                    ),
                    label: Text(runner.running ? 'Stop' : 'Record more'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: !hasNote || saving ? null : onSave,
                    icon: const Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 18,
                    ),
                    label: const Text('Save as chat'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
