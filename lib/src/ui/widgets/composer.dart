import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_session.dart';
import '../../services.dart';
import '../../voice/speech_service.dart';
import '../aithra_type.dart';

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

  void dispose() {
    text.dispose();
    focus.dispose();
    images.dispose();
  }
}

/// Text field with attach, dictate and send/stop.
class Composer extends StatefulWidget {
  const Composer({
    required this.controller,
    required this.busy,
    required this.canAttachImages,
    required this.onSend,
    required this.onStop,
    required this.onFocus,
    super.key,
  });

  final ComposerController controller;
  final bool busy;
  final bool canAttachImages;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onFocus;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  StreamSubscription<String>? _finals;
  String _beforeDictation = '';

  ComposerController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.focus.addListener(() {
      if (_c.focus.hasFocus) widget.onFocus();
    });
  }

  @override
  void dispose() {
    _finals?.cancel();
    final speech = _speech;
    if (speech != null && speech.listening) speech.cancel();
    super.dispose();
  }

  SpeechService? _speech;

  Future<void> _toggleDictation() async {
    final speech = _speech = context.services.speech;
    if (speech.listening) {
      await speech.stop();
      speech.removeListener(_onPartial);
      await _finals?.cancel();
      _finals = null;
      return;
    }
    _beforeDictation = _c.text.text;
    speech.addListener(_onPartial);
    _finals = speech.finals.listen((t) {
      _beforeDictation = _join(_beforeDictation, t);
      _c.text.text = _beforeDictation;
    });
    if (!await speech.start(continuous: true)) {
      speech.removeListener(_onPartial);
      await _finals?.cancel();
      _finals = null;
    }
  }

  void _onPartial() {
    final speech = _speech!;
    if (speech.partial.isNotEmpty) {
      _c.text.text = _join(_beforeDictation, speech.partial);
      _c.text.selection = TextSelection.collapsed(offset: _c.text.text.length);
    }
    if (!speech.listening) {
      speech.removeListener(_onPartial);
      _finals?.cancel();
      _finals = null;
    }
    if (speech.languageMissing && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'The on-device speech model for your language is missing.',
          ),
          action: SnackBarAction(
            label: 'Download',
            onPressed: speech.downloadLanguage,
          ),
        ),
      );
    } else if (speech.errorCode != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(speechErrorMessage(speech.errorCode!)),
          action: speech.micBlocked
              ? SnackBarAction(
                  label: 'Settings',
                  onPressed: speech.openAppSettings,
                )
              : null,
        ),
      );
      speech.errorCode = null;
    }
    setState(() {});
  }

  static String _join(String a, String b) =>
      a.trim().isEmpty ? b : '${a.trimRight()} $b';

  Future<void> _attach() async {
    final native = context.services.native;
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo library'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final Uint8List? jpeg;
    try {
      jpeg = source == 'camera'
          ? await native.capturePhoto()
          : await native.pickImage();
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't add the photo: ${e.message}")),
        );
      }
      return;
    }
    if (jpeg == null) return;
    _c.images.value = [..._c.images.value, PendingImage(jpeg)];
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final listening = _speech?.listening ?? false;
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
              ValueListenableBuilder<List<PendingImage>>(
                valueListenable: _c.images,
                builder: (context, images, _) => images.isEmpty
                    ? const SizedBox.shrink()
                    : SizedBox(
                        height: 76,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final img in images)
                              Padding(
                                padding: const EdgeInsets.all(4),
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
                                    Positioned(
                                      right: 0,
                                      top: 0,
                                      child: GestureDetector(
                                        onTap: () => _c.images.value = [
                                          ..._c.images.value,
                                        ]..remove(img),
                                        child: CircleAvatar(
                                          radius: 11,
                                          backgroundColor: c.textPrimary,
                                          child: Icon(
                                            Icons.close,
                                            size: 14,
                                            color: c.surface,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
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
                        style: AppTextStyles.caption.copyWith(color: c.accent),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(_c.clear),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ),
              Container(
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (widget.canAttachImages)
                      IconButton(
                        tooltip: 'Add image',
                        iconSize: 22,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        onPressed: widget.busy ? null : _attach,
                      ),
                    Expanded(
                      child: TextField(
                        controller: _c.text,
                        focusNode: _c.focus,
                        minLines: 1,
                        maxLines: 6,
                        textCapitalization: TextCapitalization.sentences,
                        style: AithraType.body.copyWith(color: c.textPrimary),
                        decoration: InputDecoration(
                          hintText: listening ? 'Listening…' : 'Message Aithra',
                          hintStyle: AithraType.body.copyWith(
                            color: c.textTertiary,
                          ),
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.fromLTRB(
                            widget.canAttachImages ? 0 : AppSpacing.md + 2,
                            15,
                            AppSpacing.xs,
                            15,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: listening ? 'Stop dictation' : 'Dictate',
                      iconSize: 22,
                      icon: Icon(
                        listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                        color: listening ? c.accent : null,
                      ),
                      onPressed: _toggleDictation,
                    ),
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: ListenableBuilder(
                        listenable: Listenable.merge([_c.text, _c.images]),
                        builder: (context, _) {
                          final canSend =
                              _c.text.text.trim().isNotEmpty ||
                              _c.images.value.isNotEmpty;
                          return IconButton.filled(
                            tooltip: widget.busy ? 'Stop' : 'Send',
                            iconSize: 20,
                            constraints: const BoxConstraints.tightFor(
                              width: 40,
                              height: 40,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: widget.busy
                                ? widget.onStop
                                : canSend
                                ? () {
                                    if (listening) _toggleDictation();
                                    HapticFeedback.lightImpact();
                                    widget.onSend();
                                  }
                                : null,
                            icon: AnimatedSwitcher(
                              duration: AppMotion.fast,
                              child: Icon(
                                widget.busy
                                    ? Icons.stop_rounded
                                    : Icons.arrow_upward_rounded,
                                key: ValueKey(widget.busy),
                              ),
                            ),
                          );
                        },
                      ),
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
}
