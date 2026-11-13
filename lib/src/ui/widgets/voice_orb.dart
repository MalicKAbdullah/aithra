import 'dart:math' as math;

import 'package:core_theme/core_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

enum OrbMood { idle, listening, thinking, speaking }

/// The voice-mode orb: soft gradient blobs in the accent and two analogous
/// hues that drift when idle, swell with the microphone level, shimmer
/// while thinking and pulse with each spoken word.
///
/// One ticker drives a [CustomPainter] through its repaint listenable, so
/// animating never rebuilds a widget; the orb sits in its own repaint
/// boundary. With reduced motion it is drawn once, still.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    required this.mood,
    required this.level,
    required this.words,
    this.size = 240,
    super.key,
  });

  final OrbMood mood;

  /// Microphone level in dB, as reported by the recognizer.
  final ValueListenable<double> level;

  /// Increments as each spoken word starts.
  final ValueListenable<int> words;
  final double size;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb>
    with SingleTickerProviderStateMixin {
  late final _OrbDriver _driver = _OrbDriver(widget.level)..mood = widget.mood;
  late final Ticker _ticker = createTicker(_driver.tick);

  @override
  void initState() {
    super.initState();
    widget.words.addListener(_driver.kick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still && _ticker.isActive) {
      _ticker.stop();
      _driver.settle();
    } else if (!still && !_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(VoiceOrb old) {
    super.didUpdateWidget(old);
    _driver.mood = widget.mood;
    if (!_ticker.isActive) _driver.settle();
    if (old.words != widget.words) {
      old.words.removeListener(_driver.kick);
      widget.words.addListener(_driver.kick);
    }
  }

  @override
  void dispose() {
    widget.words.removeListener(_driver.kick);
    _ticker.dispose();
    _driver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final dark = c.background.computeLuminance() < 0.2;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          painter: _OrbPainter(
            driver: _driver,
            palette: _OrbPalette.from(c.accent, dark: dark),
          ),
        ),
      ),
    );
  }
}

/// Animation state, advanced once per frame. Everything the painter reads
/// lives here, so a frame costs one notify and one paint.
class _OrbDriver extends ChangeNotifier {
  _OrbDriver(this._level);

  final ValueListenable<double> _level;
  OrbMood mood = OrbMood.idle;

  /// Seconds since start; drives drift and rotation.
  double t = 0;

  /// Smoothed 0–1 activity: voice level, speech pulse or thinking hum.
  double energy = 0;

  /// 0–1 fade of the thinking shimmer.
  double shimmer = 0;

  double _pulse = 0;
  Duration _last = Duration.zero;

  void kick() => _pulse = 1;

  /// Jumps to the resting look of the current mood (reduced motion).
  void settle() {
    energy = _target();
    shimmer = mood == OrbMood.thinking ? 1 : 0;
    notifyListeners();
  }

  double _target() => switch (mood) {
    OrbMood.idle => 0,
    // onRmsChanged reports about -2 dB in silence and ~10 dB for speech.
    OrbMood.listening => ((_level.value + 2) / 12).clamp(0.0, 1.0) * 0.9,
    OrbMood.thinking => 0.12,
    // A steady speaking rhythm, lifted by each word as it starts.
    OrbMood.speaking =>
      (0.22 + 0.1 * math.sin(t * 2 * math.pi * 1.6) + 0.55 * _pulse).clamp(
        0.0,
        1.0,
      ),
  };

  void tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    t += dt;
    _pulse *= math.exp(-dt * 5);
    // Rise faster than fall, so the orb snaps to a syllable and eases off.
    final target = _target();
    final rate = target > energy ? 14.0 : 5.0;
    energy += (target - energy) * (1 - math.exp(-dt * rate));
    final s = mood == OrbMood.thinking ? 1.0 : 0.0;
    shimmer += (s - shimmer) * (1 - math.exp(-dt * 4));
    notifyListeners();
  }
}

/// Three analogous hues around the accent: luminous on dark, soft on light.
@immutable
class _OrbPalette {
  const _OrbPalette(this.core, this.a, this.b, this.c, {required this.dark});

  factory _OrbPalette.from(Color accent, {required bool dark}) {
    final h = HSLColor.fromColor(accent).hue;
    Color tone(double dh, double s, double l) =>
        HSLColor.fromAHSL(1, (h + dh) % 360, s, l).toColor();
    return dark
        ? _OrbPalette(
            tone(-22, 0.78, 0.34),
            tone(0, 1, 0.6),
            tone(-38, 0.9, 0.58),
            tone(24, 1, 0.58),
            dark: true,
          )
        : _OrbPalette(
            tone(-8, 0.9, 0.72),
            tone(0, 0.95, 0.62),
            tone(-34, 0.85, 0.7),
            tone(30, 0.95, 0.66),
            dark: false,
          );
  }

  final Color core;
  final Color a;
  final Color b;
  final Color c;
  final bool dark;

  @override
  bool operator ==(Object other) =>
      other is _OrbPalette &&
      other.core == core &&
      other.a == a &&
      other.b == b &&
      other.c == c &&
      other.dark == dark;

  @override
  int get hashCode => Object.hash(core, a, b, c, dark);
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.driver, required this.palette})
    : super(repaint: driver);

  final _OrbDriver driver;
  final _OrbPalette palette;

  static const _white = Color(0xFFFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final d = driver;
    final p = palette;
    final center = size.center(Offset.zero);
    // The orb swells up to 18%; leave room for that and the glow.
    final base = size.shortestSide / 2 / 1.32;
    final r = base * (1 + 0.18 * d.energy + 0.012 * math.sin(d.t * 1.1));

    // Halo.
    final halo = r * (1.25 + 0.12 * d.energy);
    canvas.drawCircle(
      center,
      halo,
      Paint()
        ..shader = RadialGradient(
          colors: [
            p.a.withValues(alpha: (p.dark ? 0.32 : 0.22) * (0.6 + d.energy)),
            p.a.withValues(alpha: 0),
          ],
          stops: const [0.55, 1],
        ).createShader(Rect.fromCircle(center: center, radius: halo)),
    );

    final orb = Rect.fromCircle(center: center, radius: r);
    canvas
      ..save()
      ..clipPath(Path()..addOval(orb));

    // Body.
    canvas.drawRect(
      orb,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.25, -0.35),
          radius: 1.05,
          colors: [p.a, p.core],
        ).createShader(orb),
    );

    // Drifting blobs. Additive on dark so overlaps glow; plain on light.
    final blend = p.dark ? BlendMode.plus : BlendMode.srcOver;
    final t = d.t;
    void blob(Color color, double phase, double speed, double reach) {
      final a = t * speed + phase;
      final o = Offset(math.cos(a), math.sin(a * 1.3 + phase)) * (r * reach);
      final br =
          r * (0.62 + 0.08 * math.sin(t * 0.7 + phase) + 0.15 * d.energy);
      final rect = Rect.fromCircle(center: center + o, radius: br);
      canvas.drawCircle(
        center + o,
        br,
        Paint()
          ..blendMode = blend
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: p.dark ? 0.42 : 0.75),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    }

    blob(p.b, 0, 0.45, 0.42);
    blob(p.c, 2.1, -0.38, 0.4);
    blob(p.a, 4.2, 0.3, 0.3);

    // Thinking shimmer: a soft band of light sweeping round.
    if (d.shimmer > 0.01) {
      canvas.drawRect(
        orb,
        Paint()
          ..shader = SweepGradient(
            transform: GradientRotation(t * 2.4),
            colors: [
              _white.withValues(alpha: 0),
              _white.withValues(alpha: 0.28 * d.shimmer),
              _white.withValues(alpha: 0),
              _white.withValues(alpha: 0),
            ],
            stops: const [0, 0.12, 0.3, 1],
          ).createShader(orb),
      );
    }

    // Specular highlight.
    final spec = Rect.fromCircle(
      center: center + Offset(-r * 0.32, -r * 0.4),
      radius: r * 0.55,
    );
    canvas
      ..drawOval(
        spec,
        Paint()
          ..shader = RadialGradient(
            colors: [
              _white.withValues(alpha: p.dark ? 0.32 : 0.45),
              _white.withValues(alpha: 0),
            ],
          ).createShader(spec),
      )
      ..restore();

    // Rim.
    canvas.drawCircle(
      center,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _white.withValues(alpha: p.dark ? 0.1 : 0.35),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.palette != palette || old.driver != driver;
}
