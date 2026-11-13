import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_session.dart';
import '../../services.dart';
import '../../voice/sentence_splitter.dart';
import '../../voice/speech_service.dart';

enum VoicePhase { listening, thinking, speaking, paused }

/// Hands-free conversation: listen → answer → speak → listen again. Speaking
/// starts with the first complete sentence while the rest still generates.
/// Tapping the orb interrupts and listens again.
class VoiceModeScreen extends StatefulWidget {
  const VoiceModeScreen({super.key});

  @override
  State<VoiceModeScreen> createState() => _VoiceModeScreenState();
}

class _VoiceModeScreenState extends State<VoiceModeScreen>
    with SingleTickerProviderStateMixin {
  late final Services _s;
  late final ChatSession _session;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);
  StreamSubscription<String>? _finals;
  VoicePhase _phase = VoicePhase.paused;
  String _heard = '';
  String _reply = '';
  SentenceSplitter? _splitter;
  int _spokenUpTo = 0;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _s = context.services;
    _session = ChatSession(
      native: _s.native,
      assistant: _s.assistant,
      store: _s.chats,
      memories: _s.memories,
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
    _pulse.dispose();
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

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final speech = _s.speech;
    final label = switch (_phase) {
      VoicePhase.listening => 'Listening',
      VoicePhase.thinking => 'Thinking',
      VoicePhase.speaking => 'Speaking · tap to interrupt',
      VoicePhase.paused => 'Tap to talk',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Voice mode')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  reverse: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_heard.isNotEmpty)
                        Text(
                          _heard,
                          style: AppTextStyles.h3.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      const SizedBox(height: AppSpacing.lg),
                      if (_reply.isNotEmpty)
                        Text(
                          speakable(_reply),
                          style: AppTextStyles.body.copyWith(
                            color: c.textPrimary,
                            height: 1.5,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (speech.languageMissing)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Column(
                    children: [
                      Text(
                        'The on-device speech model for your language is not installed.',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                      TextButton(
                        onPressed: speech.downloadLanguage,
                        child: const Text('Download it'),
                      ),
                    ],
                  ),
                )
              else if (speech.errorCode != null && _phase == VoicePhase.paused)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Text(
                    speechErrorMessage(speech.errorCode!),
                    style: AppTextStyles.bodySmall.copyWith(color: c.negative),
                  ),
                ),
              GestureDetector(
                onTap: _interrupt,
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) {
                    final level = _phase == VoicePhase.listening
                        ? ((speech.level + 2) / 12).clamp(0.0, 1.0)
                        : _phase == VoicePhase.paused
                        ? 0.0
                        : _pulse.value;
                    return Container(
                      width: 140 + 40 * level,
                      height: 140 + 40 * level,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            c.accent,
                            c.accent.withValues(
                              alpha: _phase == VoicePhase.paused ? 0.25 : 0.55,
                            ),
                          ],
                        ),
                      ),
                      child: Icon(
                        switch (_phase) {
                          VoicePhase.listening => Icons.mic_rounded,
                          VoicePhase.thinking => Icons.more_horiz_rounded,
                          VoicePhase.speaking => Icons.graphic_eq_rounded,
                          VoicePhase.paused => Icons.mic_none_rounded,
                        },
                        size: 52,
                        color: c.onAccent,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                label,
                style: AppTextStyles.labelStrong.copyWith(
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}
