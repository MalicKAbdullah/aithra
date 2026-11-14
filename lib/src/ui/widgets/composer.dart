import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_session.dart';
import '../../voice/speech_service.dart';
import '../../voice/dictation.dart';
import '../aithra_type.dart';
import 'composer_attach.dart';
import 'recording_bar.dart';
import 'speech_notice.dart';

class ComposerController {
  final TextEditingController text = TextEditingController();
  final FocusNode focus = FocusNode();
  final ValueNotifier<List<PendingImage>> images = ValueNotifier(const []);

  /// The next send replaces the last user message.
  bool editing = false;

  void clear() {
    text.clear();
    images.value = const [];
    editing = false;
  }

  /// Puts [value] in the field with the caret at its end.
  void setText(String value) => text.value = TextEditingValue(
    text: value,
    selection: TextSelection.collapsed(offset: value.length),
  );

  void dispose() {
    text.dispose();
    focus.dispose();
    images.dispose();
  }
}

/// Text field with attach, dictate and send/stop. While dictating, the row
/// cross-fades into a [RecordingBar] of the same height, with the
/// transcript in a fixed two-line strip above it.
class Composer extends StatefulWidget {
  const Composer({
    required this.controller,
    required this.speech,
    required this.busy,
    required this.canAttachImages,
    required this.onSend,
    required this.onStop,
    required this.onFocus,
    super.key,
  });

  final ComposerController controller;
  final SpeechService speech;
  final bool busy;
  final bool canAttachImages;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onFocus;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer>
    with SingleTickerProviderStateMixin {
  late final Dictation _dictation;
  late final AnimationController _mode = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );

  /// The field's text when dictation started; finals are appended to it.
  String _before = '';

  ComposerController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _dictation = Dictation(widget.speech)
      ..onFinal = _onFinal
      ..onEnd = _onDictationEnd;
    _c.focus.addListener(_onFocusChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mode.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 150);
  }

  void _onFocusChange() {
    if (_c.focus.hasFocus) widget.onFocus();
  }

  @override
  void dispose() {
    _c.focus.removeListener(_onFocusChange);
    _dictation.dispose();
    _mode.dispose();
    super.dispose();
  }

  Future<void> _dictate() async {
    _c.focus.unfocus();
    _before = _c.text.text;
    unawaited(_mode.forward());
    await _dictation.start();
  }

  void _onFinal(String committed) => _c.setText(joinSpeech(_before, committed));

  void _onDictationEnd(DictationEnd end, String committed) {
    switch (end) {
      case DictationEnd.cancelled:
        _c.setText(_before);
      case DictationEnd.failed:
        if (mounted) showSpeechProblem(context, _dictation.speech);
      case DictationEnd.done:
        break;
    }
    if (mounted) unawaited(_mode.reverse());
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Material(
      color: c.background,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.xs,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PendingImages(_c),
              if (_c.editing)
                Padding(
                  padding: const EdgeInsets.only(
                    left: AppSpacing.md,
                    bottom: AppSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined, size: 16, color: c.accent),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        'Editing your last message',
                        style: AithraType.caption.copyWith(color: c.accent),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(_c.clear),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ),
              ValueListenableBuilder<DictationPhase>(
                valueListenable: _dictation.phase,
                builder: (context, phase, _) => phase == DictationPhase.idle
                    ? const SizedBox.shrink()
                    : FadeTransition(
                        opacity: _mode,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.md,
                            AppSpacing.xs,
                            AppSpacing.md,
                            AppSpacing.sm,
                          ),
                          child: DictationTranscript(dictation: _dictation),
                        ),
                      ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(composerInset),
                  // Buttons lay out at their 40 dp, not padded to 48: the
                  // padding would make the row taller than the recording
                  // bar and offset one from the other. The inset around
                  // them keeps neighbouring targets apart.
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: ValueListenableBuilder<DictationPhase>(
                      valueListenable: _dictation.phase,
                      builder: (context, phase, _) => _swap(
                        context,
                        recording: phase != DictationPhase.idle,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The input row and the recording bar, cross-faded. While recording the
  /// stack is pinned to one row's height and the row (which may have grown
  /// with typed or dictated text) is clipped from the top, so nothing
  /// around the composer moves as text arrives.
  Widget _swap(BuildContext context, {required bool recording}) {
    final row = IgnorePointer(
      ignoring: recording,
      child: FadeTransition(
        opacity: ReverseAnimation(_mode),
        child: _inputRow(context),
      ),
    );
    final bar = AnimatedBuilder(
      animation: _mode,
      builder: (context, child) => _mode.isDismissed && !recording
          ? const SizedBox.shrink()
          : IgnorePointer(
              ignoring: !recording,
              child: FadeTransition(opacity: _mode, child: child),
            ),
      child: RecordingBar(
        dictation: _dictation,
        onCancel: _dictation.cancel,
        onDone: _dictation.finish,
      ),
    );
    if (recording) {
      return SizedBox(
        height: composerButton,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: OverflowBox(
                alignment: Alignment.bottomCenter,
                minHeight: 0,
                maxHeight: double.infinity,
                child: row,
              ),
            ),
            bar,
          ],
        ),
      );
    }
    return Stack(
      children: [
        row,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: composerButton,
          child: bar,
        ),
      ],
    );
  }

  Widget _inputRow(BuildContext context) {
    final c = SuiteColors.of(context);
    const button = BoxConstraints.tightFor(
      width: composerButton,
      height: composerButton,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (widget.canAttachImages) ...[
          ComposerAttachButton(controller: _c, enabled: !widget.busy),
          const SizedBox(width: AppSpacing.xs),
        ],
        Expanded(
          child: TextField(
            controller: _c.text,
            focusNode: _c.focus,
            minLines: 1,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            style: AithraType.body.copyWith(color: c.textPrimary),
            decoration: InputDecoration(
              hintText: 'Message Aithra',
              hintStyle: AithraType.body.copyWith(color: c.textTertiary),
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              constraints: const BoxConstraints(minHeight: composerButton),
              // One line of body text centred on the 40 dp buttons; with the
              // attach button absent the text starts on the transcript's
              // inset.
              contentPadding: EdgeInsets.fromLTRB(
                widget.canAttachImages ? 0 : AppSpacing.md - composerInset,
                9,
                AppSpacing.xs,
                9,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Dictate',
          iconSize: 22,
          constraints: button,
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.mic_none_rounded),
          onPressed: _dictate,
        ),
        const SizedBox(width: AppSpacing.xs),
        ListenableBuilder(
          listenable: Listenable.merge([_c.text, _c.images]),
          builder: (context, _) {
            final canSend =
                _c.text.text.trim().isNotEmpty || _c.images.value.isNotEmpty;
            return IconButton.filled(
              tooltip: widget.busy ? 'Stop' : 'Send',
              iconSize: 20,
              constraints: button,
              padding: EdgeInsets.zero,
              onPressed: widget.busy
                  ? widget.onStop
                  : canSend
                  ? () {
                      HapticFeedback.lightImpact();
                      widget.onSend();
                    }
                  : null,
              icon: AnimatedSwitcher(
                duration: AppMotion.fast,
                child: Icon(
                  widget.busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                  key: ValueKey(widget.busy),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Photos waiting to be sent, each with a remove button.
class _PendingImages extends StatelessWidget {
  const _PendingImages(this.c);

  final ComposerController c;

  @override
  Widget build(BuildContext context) {
    final colors = SuiteColors.of(context);
    return ValueListenableBuilder<List<PendingImage>>(
      valueListenable: c.images,
      builder: (context, images, _) => images.isEmpty
          ? const SizedBox.shrink()
          : SizedBox(
              height: 76,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final (i, img) in images.indexed)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: SizedBox.square(
                        dimension: 68,
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                AppSpacing.radiusMd,
                              ),
                              child: Image.memory(
                                img.jpeg,
                                width: 68,
                                height: 68,
                                fit: BoxFit.cover,
                                cacheWidth: 200,
                              ),
                            ),
                            // The 22 dp badge sits in the corner of a 40 dp
                            // target, so it stays easy to hit.
                            Positioned(
                              right: 0,
                              top: 0,
                              child: Semantics(
                                button: true,
                                label: images.length == 1
                                    ? 'Remove photo'
                                    : 'Remove photo ${i + 1}',
                                excludeSemantics: true,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () =>
                                      c.images.value = [...c.images.value]
                                        ..remove(img),
                                  child: SizedBox.square(
                                    dimension: 40,
                                    child: Align(
                                      alignment: const Alignment(0.7, -0.7),
                                      child: CircleAvatar(
                                        radius: 11,
                                        backgroundColor: colors.textPrimary,
                                        child: Icon(
                                          Icons.close,
                                          size: 14,
                                          color: colors.surface,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
