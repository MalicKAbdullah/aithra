import 'package:flutter/material.dart';

/// The ember of Aithra's launcher icon. The mark keeps this exact colour in
/// both themes so it always matches the icon on the home screen.
const Color aithraBrand = Color(0xFFC2410C);

/// Aithra's mark: the launcher icon's spark on an ember tile.
class AithraMark extends StatelessWidget {
  const AithraMark({this.size = 40, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: aithraBrand,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: const CustomPaint(painter: AithraGlyphPainter()),
    ),
  );
}

/// The spark glyph, drawn from the same 24-unit path as the launcher icon's
/// vector foreground, centred at 60% of the box.
class AithraGlyphPainter extends CustomPainter {
  const AithraGlyphPainter({this.color = Colors.white});

  final Color color;

  static final Path _spark = Path()
    ..moveTo(10.5, 4.5)
    ..quadraticBezierTo(11.5, 11.5, 18, 12.5)
    ..quadraticBezierTo(11.5, 13.5, 10.5, 20.5)
    ..quadraticBezierTo(9.5, 13.5, 3, 12.5)
    ..quadraticBezierTo(9.5, 11.5, 10.5, 4.5)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide * 0.6 / 24;
    canvas
      ..save()
      ..translate((size.width - 24 * scale) / 2, (size.height - 24 * scale) / 2)
      ..scale(scale);
    canvas
      ..drawPath(
        _spark,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      )
      ..drawCircle(const Offset(18.5, 6), 2, Paint()..color = color)
      ..restore();
  }

  @override
  bool shouldRepaint(AithraGlyphPainter old) => old.color != color;
}
