import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

/// Aithra's mark: a rounded ember tile with a spark.
class AithraMark extends StatelessWidget {
  const AithraMark({this.size = 40, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.accent,
            Color.lerp(c.accent, const Color(0xFFFFC56B), 0.45)!,
          ],
        ),
      ),
      child: Icon(Icons.auto_awesome, size: size * 0.55, color: c.onAccent),
    );
  }
}
