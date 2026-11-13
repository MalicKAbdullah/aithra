import 'dart:async';
import 'dart:math' as math;

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_session.dart';
import '../../services.dart';
import '../../voice/sentence_splitter.dart';
import '../../voice/speech_service.dart';
import '../aithra_type.dart';
import '../widgets/speech_notice.dart';
import '../widgets/voice_orb.dart';
import 'chat_screen.dart';

enum VoicePhase { listening, thinking, speaking, paused }

/// Hands-free conversation: listen → answer → speak → listen again. Speaking
/// starts with the first complete sentence while the rest still generates.
/// Tapping the orb interrupts and listens again.
class VoiceModeScreen extends StatefulWidget {
  const VoiceModeScreen({super.key});

  @override
  State<VoiceModeScreen> createState() => _VoiceModeScreenState();
}

class _VoiceModeScreenState extends State<VoiceModeScreen> {
  late final Services _s;
  late final ChatSession _session;
  StreamSubscription<String>? _finals;
  VoicePhase _phase = VoicePhase.paused;
  String _heard = '';
  String _reply = '';
  SentenceSplitter? _splitter;
  int _spokenUpTo = 0;
  bool _closing = false;
  bool _modelInstalled = false;

  @override
  void initState() {
    super.initState();
    _s = context.services;
    _session = ChatSession(
      native: _s.native,
      assistant: _s.assistant,
      store: _s.chats,
      memories: _s.memories,
      recall: _s.recall,
      suggestFacts: false,
    );
    _session.streaming.addListener(_onReplyText);
    _s.speech.addListener(_onSpeech);
    _finals = _s.speech.finals.listen(_onHeard);
    _s.assistant.warmUp();
    _listen();
  }

  @override
  void dispose() {
    _closing = true;
    _finals?.cancel();
    _s.speech.removeListener(_onSpeech);
    _session.streaming.removeListener(_onReplyText);
    _s.speech.cancel();
    _s.tts.stop();
    _session.dispose();
    super.dispose();
  }

  Future<void> _listen() async {
    if (_closing) return;
    setState(() {
      _phase = VoicePhase.listening;
      _heard = '';
    });
    if (!await _s.speech.start(continuous: false)) {
      setState(() => _phase = VoicePhase.paused);
    }
  }

  void _onSpeech() {
    if (!mounted) return;
    final installed = _s.speech.download.phase == DownloadPhase.done;
    if (installed && !_modelInstalled && _phase == VoicePhase.paused) {
      // The model the user asked for just arrived: carry on listening.
      _modelInstalled = installed;
      unawaited(_listen());
      return;
    }
    _modelInstalled = installed;
    if (_phase == VoicePhase.listening) {
      if (_s.speech.partial.isNotEmpty) _heard = _s.speech.partial;
      if (!_s.speech.listening && _s.speech.errorCode != null) {
        _phase = VoicePhase.paused;
      } else if (!_s.speech.listening && _heard.isEmpty) {
        // Silence: keep listening.
        unawaited(_listen());
        return;
      }
    }
    setState(() {});
  }

  Future<void> _onHeard(String text) async {
    if (_phase != VoicePhase.listening || text.trim().isEmpty) return;
    setState(() {
      _heard = text;
      _reply = '';
      _phase = VoicePhase.thinking;
    });
    _splitter = SentenceSplitter();
    _spokenUpTo = 0;
    await _session.send(text, const []);
    // The reply is complete: speak what is left, then listen again.
    final splitter = _splitter;
    if (splitter != null) {
      final full = _session.lastReply;
      final tail = full.length > _spokenUpTo ? full.substring(_spokenUpTo) : '';
      for (final sentence in [...splitter.add(tail), ...splitter.flush()]) {
        await _s.tts.say(sentence);
      }
      if (mounted) setState(() => _reply = full);
    }
    _splitter = null;
    if (_session.error != null) {
      await _s.tts.say(_session.error!);
    }
    await _s.tts.idle;
    if (mounted && !_closing && _phase != VoicePhase.listening) await _listen();
  }

  void _onReplyText() {
    final text = _session.streaming.value;
    final splitter = _splitter;
    if (splitter == null || text.length <= _spokenUpTo) return;
    final chunk = text.substring(_spokenUpTo);
    _spokenUpTo = text.length;
    final sentences = splitter.add(chunk);
    if (sentences.isNotEmpty && _phase == VoicePhase.thinking) {
      setState(() => _phase = VoicePhase.speaking);
    }
    for (final s in sentences) {
      _s.tts.say(s);
    }
    setState(() => _reply = text);
  }

  Future<void> _interrupt() async {
    HapticFeedback.mediumImpact();
    switch (_phase) {
      case VoicePhase.thinking:
      case VoicePhase.speaking:
        _splitter = null;
        await _s.tts.stop();
        await _session.stop();
        await _listen();
      case VoicePhase.listening:
        await _s.speech.stop();
      case VoicePhase.paused:
        await _listen();
    }
  }

  void _typeInstead() {
    final conversation = _session.conversation;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(conversation: conversation),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final speech = _s.speech;
    final label = switch (_phase) {
      VoicePhase.listening => 'Listening',
      VoicePhase.thinking => 'Thinking',
      VoicePhase.speaking => 'Speaking · tap to stop',
      VoicePhase.paused => 'Tap to talk',
    };
    final mood = switch (_phase) {
      VoicePhase.listening => OrbMood.listening,
      VoicePhase.thinking => OrbMood.thinking,
      VoicePhase.speaking => OrbMood.speaking,
      VoicePhase.paused => OrbMood.idle,
    };
    final modelNotice = speech.modelNotice;
    final notice = modelNotice != null
        ? null
        : speech.errorCode != null && _phase == VoicePhase.paused
        ? speechErrorMessage(speech.errorCode!)
        : null;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            const bar = 56.0;
            final orb = math.min(260.0, box.maxWidth * 0.66);
            // The orb's centre sits on the screen's vertical middle; the
            // transcript fills the space above it and never reaches it.
            final half = (box.maxHeight - orb) / 2;
            return Column(
              children: [
                SizedBox(
                  height: bar,
                  child: Row(
                    children: [
                      const SizedBox(width: AppSpacing.xs),
                      IconButton(
                        tooltip: 'Close voice mode',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: math.max(0, half - bar),
                  child: _Transcript(heard: _heard, reply: _reply),
                ),
                GestureDetector(
                  onTap: _interrupt,
                  child: Semantics(
                    button: true,
                    label: label,
                    child: VoiceOrb(
                      mood: mood,
                      level: speech.level,
                      words: _s.tts.words,
                      size: orb,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.gutter,
                    ),
                    child: Column(
                      children: [
                        const SizedBox(height: AppSpacing.xs),
                        AnimatedSwitcher(
                          duration: AppMotion.fast,
                          child: Text(
                            label,
                            key: ValueKey(label),
                            style: AithraType.label.copyWith(
                              color: c.textSecondary,
                            ),
                          ),
                        ),
                        if (modelNotice != null) ...[
                          const SizedBox(height: AppSpacing.sm),
                          SpeechNoticeView(speech: speech, notice: modelNotice),
                        ] else if (notice != null) ...[
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            notice,
                            textAlign: TextAlign.center,
                            style: AithraType.bodySmall.copyWith(
                              color: c.negative,
                            ),
                          ),
                          if (speech.micBlocked)
                            TextButton(
                              onPressed: speech.openAppSettings,
                              child: const Text('Open Settings'),
                            ),
                        ],
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _typeInstead,
                          icon: const Icon(Icons.keyboard_rounded, size: 18),
                          label: const Text('Type instead'),
                          style: TextButton.styleFrom(
                            foregroundColor: c.textSecondary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                    ),
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

/// What was heard and the reply so far, newest at the bottom, fading out at
/// the top edge as it scrolls.
class _Transcript extends StatelessWidget {
  const _Transcript({required this.heard, required this.reply});

  final String heard;
  final String reply;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            reverse: true,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.lg,
              AppSpacing.gutter,
              AppSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (heard.isNotEmpty)
                  Text(
                    heard,
                    textAlign: TextAlign.center,
                    style: AithraType.title.copyWith(
                      color: c.textSecondary,
                      fontSize: 16,
                    ),
                  ),
                if (heard.isNotEmpty && reply.isNotEmpty)
                  const SizedBox(height: AppSpacing.md),
                if (reply.isNotEmpty)
                  Text(
                    speakable(reply),
                    textAlign: TextAlign.center,
                    style: AithraType.body.copyWith(
                      color: c.textPrimary,
                      fontSize: 17,
                      height: 1.5,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: AppSpacing.xxl,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [c.background, c.background.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
