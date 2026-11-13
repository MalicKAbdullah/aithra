import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../aithra_type.dart';
import 'aithra_mark.dart';

/// "Good morning" and so on, for the hour of [now].
String greetingFor(DateTime now) => switch (now.hour) {
  >= 5 && < 12 => 'Good morning',
  >= 12 && < 17 => 'Good afternoon',
  >= 17 && < 22 => 'Good evening',
  _ => 'Hello, night owl',
};

/// A new chat's empty state: the mark and a greeting for the time of day,
/// rising gently into place. Only opacity and a transform animate, both on
/// the compositor, so it holds the display's full frame rate.
class Greeting extends StatefulWidget {
  const Greeting({required this.now, super.key});

  final DateTime now;

  @override
  State<Greeting> createState() => _GreetingState();
}

class _GreetingState extends State<Greeting>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 640),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _in,
    curve: const Interval(0, 0.8, curve: Curves.easeOut),
  );
  late final Animation<Offset> _rise = Tween(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _in, curve: AppMotion.emphasized));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _in.value = 1;
    } else if (_in.isDismissed) {
      _in.forward();
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Align(
      alignment: const Alignment(0, -0.2),
      child: FadeTransition(
        opacity: _fade,
        child: SlideTransition(
          position: _rise,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AithraMark(size: 44),
                const SizedBox(height: AppSpacing.mdl),
                Text(
                  greetingFor(widget.now),
                  textAlign: TextAlign.center,
                  style: AithraType.display.copyWith(color: c.textPrimary),
                ),
                const SizedBox(height: AppSpacing.sm - 2),
                Text(
                  'How can I help today?',
                  textAlign: TextAlign.center,
                  style: AithraType.body.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
