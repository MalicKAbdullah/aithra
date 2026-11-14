import 'package:flutter/material.dart';

import '../../quick_actions.dart';
import '../../services.dart';
import '../screens/voice_mode_screen.dart';
import '../screens/voice_note_screen.dart';

/// Carries out launcher shortcuts and the Quick Settings tile on the home
/// screen: whatever was open closes, then the action's screen opens.
class QuickActionHandler extends StatefulWidget {
  const QuickActionHandler({required this.child, super.key});

  final Widget child;

  @override
  State<QuickActionHandler> createState() => _QuickActionHandlerState();
}

class _QuickActionHandlerState extends State<QuickActionHandler> {
  late final QuickActions _actions = context.services.quickActions;

  @override
  void initState() {
    super.initState();
    _actions.addListener(_handle);
    _actions.check();
  }

  @override
  void dispose() {
    _actions.removeListener(_handle);
    super.dispose();
  }

  void _handle() {
    final action = _actions.take();
    if (action == null || !mounted) return;
    final s = context.services;
    final nav = Navigator.of(context)..popUntil((r) => r.isFirst);
    void push(Widget screen) =>
        nav.push(MaterialPageRoute<void>(builder: (_) => screen));
    switch (action) {
      case QuickAction.newChat:
        s.sessions.startNew();
      case QuickAction.voiceMode:
        push(const VoiceModeScreen());
      case QuickAction.voiceNote:
        push(const VoiceNoteScreen());
      case QuickAction.askPhoto:
        s.sessions.startNew();
        _actions.requestPhoto();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
