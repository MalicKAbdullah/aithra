import 'dart:async';
import 'dart:math' as math;

import 'package:core_theme/core_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../voice/dictation.dart';
import '../aithra_type.dart';

/// The composer's buttons and the recording bar's share one size and one
/// inset, so swapping the two rows moves nothing.
const double composerButton = 40;
const double composerInset = 6;

/// Height of the composer's idle row and of the recording bar.
const double composerRowHeight = composerButton + 2 * composerInset;

/// Cancel | live waveform | elapsed time | Done, at the composer's idle
/// height. Only the waveform animates, on its own ticker and layer.
class RecordingBar extends StatelessWidget {
  const RecordingBar({
    required this.dictation,
    required this.onCancel,
    required this.onDone,
    super.key,
  });

  final Dictation dictation;
  final VoidCallback onCancel;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return SizedBox(
      height: composerButton,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Cancel dictation',
            iconSize: 22,
            constraints: const BoxConstraints.tightFor(
              width: composerButton,
              height: composerButton,
            ),
            padding: EdgeInsets.zero,
            color: c.textSecondary,
            icon: const Icon(Icons.close_rounded),
            onPressed: onCancel,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: ValueListenableBuilder<DictationPhase>(
              valueListenable: dictation.phase,
              builder: (context, phase, _) => Waveform(
                level: dictation.level,
                live: phase == DictationPhase.listening,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.smd),
          _Elapsed(dictation),
          const SizedBox(width: AppSpacing.smd),
          ValueListenableBuilder<DictationPhase>(
            valueListenable: dictation.phase,
            builder: (context, phase, _) => IconButton.filled(
              tooltip: 'Done',
              iconSize: 22,
              constraints: const BoxConstraints.tightFor(
                width: composerButton,
                height: composerButton,
              ),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.onAccent,
                disabledBackgroundColor: c.accent.withValues(alpha: 0.45),
                disabledForegroundColor: c.onAccent,
              ),
              icon: const Icon(Icons.check_rounded),
              onPressed: phase == DictationPhase.listening ? onDone : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Minutes and seconds since listening started, in tabular figures so the
/// digits never shift. Rebuilds once a second, even with reduced motion.
class _Elapsed extends StatefulWidget {
  const _Elapsed(this.dictation);

  final Dictation dictation;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  late final Timer _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _seconds = widget.dictation.elapsed.elapsed.inSeconds;
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
  }

  void _tick() {
    final s = widget.dictation.elapsed.elapsed.inSeconds;
    if (s != _seconds) setState(() => _seconds = s);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final text = formatElapsed(Duration(seconds: _seconds));
    return Semantics(
      label: 'Recording, $text',
      excludeSemantics: true,
      child: Text(
        text,
        style: AithraType.number.copyWith(fontSize: 14, color: c.textSecondary),
      ),
    );
  }
}

String formatElapsed(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// What has been said so far: committed text in the primary colour, the
/// utterance being recognised in the secondary one. A fixed two lines that
/// keep the newest words in view, so it never changes the composer's
/// height while the user speaks.
class DictationTranscript extends StatelessWidget {
  const DictationTranscript({
    required this.dictation,
    this.lines = 2,
    this.style,
    this.placeholder = 'Listening…',
    super.key,
  });

  final Dictation dictation;
  final int lines;
  final TextStyle? style;
  final String placeholder;

  /// Height of [lines] lines of [style] under the current text scale.
  static double heightFor(BuildContext context, TextStyle style, int lines) =>
      MediaQuery.textScalerOf(context).scale(style.fontSize!) *
      style.height! *
      lines;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final base = style ?? AithraType.body;
    return SizedBox(
      height: heightFor(context, base, lines),
      child: ListenableBuilder(
        listenable: Listenable.merge([dictation.committed, dictation.partial]),
        builder: (context, _) {
          final committed = dictation.committed.value;
          final partial = dictation.partial.value;
          final empty = committed.isEmpty && partial.isEmpty;
          return SingleChildScrollView(
            // Reversed, so the end of the text (the newest words) is what
            // stays in view as it grows.
            reverse: true,
            physics: const NeverScrollableScrollPhysics(),
            child: Text.rich(
              empty
                  ? TextSpan(
                      text: placeholder,
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
              style: base,
            ),
          );
        },
      ),
    );
  }
}

/// A scrolling level meter: one bar per 50 ms of the smoothed microphone
/// level, newest on the right, sliding left continuously between samples.
/// A ticker drives the painter directly, so a frame is one paint of one
/// layer and never a rebuild. With reduced motion the bars stand still.
class Waveform extends StatefulWidget {
  const Waveform({
    required this.level,
    required this.live,
    this.height = 28,
    super.key,
  });

  /// Microphone level in dB, as `onRmsChanged` reports it.
  final ValueListenable<double> level;

  /// Whether the microphone is still being heard; when not, the bars
  /// settle to silence.
  final bool live;
  final double height;

  @override
  State<Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<Waveform>
    with SingleTickerProviderStateMixin {
  late final WaveformDriver _driver = WaveformDriver(widget.level);
  late final Ticker _ticker = createTicker(_driver.tick);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still && _ticker.isActive) {
      _ticker.stop();
      _driver.still();
    } else if (!still && !_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(Waveform old) {
    super.didUpdateWidget(old);
    _driver.live = widget.live;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _driver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: _WaveformPainter(_driver, c.accent, c.textTertiary),
        ),
      ),
    );
  }
}

/// The waveform's state, advanced once per frame.
class WaveformDriver extends ChangeNotifier {
  WaveformDriver(this._level);

  static const int bars = 40;
  static const double sampleSeconds = 0.05;

  /// Time constants of the level envelope: it rises within a syllable and
  /// falls slowly enough that words read as shapes rather than flicker.
  static const double attackSeconds = 0.06;
  static const double releaseSeconds = 0.25;

  final ValueListenable<double> _level;
  bool live = true;

  /// Bar heights 0–1, a ring with its newest sample at [_head].
  final Float32List samples = Float32List(bars);
  int _head = bars - 1;

  /// Smoothed level, 0–1.
  double envelope = 0;

  /// 0–1 progress towards the next sample; the bars slide by this much of
  /// one bar pitch so the motion is continuous at any frame rate.
  double phase = 0;
  double _acc = 0;
  Duration _last = Duration.zero;

  /// The [i]th bar from the oldest (0) to the newest ([bars] - 1).
  double sample(int i) => samples[(_head + 1 + i) % bars];

  /// onRmsChanged reports about -2 dB in silence and ~10 dB for speech.
  static double normalise(double db) => ((db + 2) / 12).clamp(0.0, 1.0);

  void tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    advance(dt);
    notifyListeners();
  }

  /// Moves the envelope and the ring on by [dt] seconds.
  void advance(double dt) {
    final target = live ? normalise(_level.value) : 0.0;
    final tau = target > envelope ? attackSeconds : releaseSeconds;
    envelope += (target - envelope) * (1 - math.exp(-dt / tau));
    _acc += dt;
    while (_acc >= sampleSeconds) {
      _acc -= sampleSeconds;
      _head = (_head + 1) % bars;
      samples[_head] = envelope;
    }
    phase = _acc / sampleSeconds;
  }

  /// Flat, motionless bars for reduced motion.
  void still() {
    samples.fillRange(0, bars, 0);
    envelope = 0;
    phase = 0;
    notifyListeners();
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.driver, this.color, this.rest) : super(repaint: driver);

  final WaveformDriver driver;
  final Color color;
  final Color rest;

  @override
  void paint(Canvas canvas, Size size) {
    const n = WaveformDriver.bars;
    final pitch = size.width / n;
    final width = math.min(3.0, pitch * 0.55);
    final minH = width;
    final mid = size.height / 2;
    final shift = driver.phase * pitch;
    final paint = Paint();
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = 0; i < n; i++) {
      final v = driver.sample(i);
      final h = minH + (size.height - minH) * v;
      // Bars are centred in their slot; the slot slides left between
      // samples and the oldest one fades out at the left edge.
      final x = (i + 0.5) * pitch - shift;
      final age = i / (n - 1);
      final fade = ((x + pitch / 2) / pitch).clamp(0.0, 1.0);
      paint.color = Color.lerp(
        rest,
        color,
        v.clamp(0.0, 1.0) * 0.7 + 0.3,
      )!.withValues(alpha: (0.35 + 0.65 * age) * fade);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x, mid), width: width, height: h),
          Radius.circular(width / 2),
        ),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.driver != driver || old.color != color || old.rest != rest;
}
