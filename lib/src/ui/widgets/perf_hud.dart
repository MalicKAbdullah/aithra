import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../engine/run_metrics.dart';
import '../../services.dart';

/// Rolling frame statistics from the engine's real frame timings.
class FrameStats {
  final List<FrameTiming> _recent = [];

  void add(List<FrameTiming> timings) {
    _recent.addAll(timings);
    if (_recent.length > 120) _recent.removeRange(0, _recent.length - 120);
  }

  double _avg(Duration Function(FrameTiming) f) => _recent.isEmpty
      ? 0
      : _recent.map((t) => f(t).inMicroseconds).reduce((a, b) => a + b) /
            _recent.length /
            1000;

  double get buildMs => _avg((t) => t.buildDuration);
  double get rasterMs => _avg((t) => t.rasterDuration);

  /// Frames slower than [budgetMs] in build or raster.
  int janky(double budgetMs) => _recent
      .where(
        (t) =>
            t.buildDuration.inMicroseconds / 1000 > budgetMs ||
            t.rasterDuration.inMicroseconds / 1000 > budgetMs,
      )
      .length;
}

/// A small overlay with the last reply's speed and live frame times.
/// Enabled in Settings → Performance.
class PerfHud extends StatefulWidget {
  const PerfHud({super.key});

  @override
  State<PerfHud> createState() => _PerfHudState();
}

class _PerfHudState extends State<PerfHud> {
  final _stats = FrameStats();
  bool _listening = false;

  void _onTimings(List<FrameTiming> t) {
    _stats.add(t);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_listening) SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return ListenableBuilder(
      listenable: s.settings,
      builder: (context, _) {
        final on = s.settings.perfOverlay;
        if (on && !_listening) {
          SchedulerBinding.instance.addTimingsCallback(_onTimings);
          _listening = true;
        } else if (!on && _listening) {
          SchedulerBinding.instance.removeTimingsCallback(_onTimings);
          _listening = false;
        }
        if (!on) return const SizedBox.shrink();
        final hz = View.of(context).display.refreshRate;
        final budget = 1000 / hz;
        return Positioned(
          right: 8,
          top: 8,
          child: IgnorePointer(
            child: ValueListenableBuilder<RunMetrics?>(
              valueListenable: s.engine.lastRun,
              builder: (context, run, _) => Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DefaultTextStyle(
                  style: AppTextStyles.code.copyWith(
                    color: Colors.white,
                    fontSize: 11,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'decode ${run?.decodeTps?.toStringAsFixed(1) ?? '—'} tok/s',
                      ),
                      Text(
                        'prefill ${run?.prefillTps?.toStringAsFixed(0) ?? '—'} tok/s',
                      ),
                      Text(
                        'TTFT ${run?.ttftMs == null ? '—' : '${(run!.ttftMs! / 1000).toStringAsFixed(2)} s'}',
                      ),
                      Text('build ${_stats.buildMs.toStringAsFixed(1)} ms'),
                      Text('raster ${_stats.rasterMs.toStringAsFixed(1)} ms'),
                      Text('slow ${_stats.janky(budget)}/120 @${hz.round()}Hz'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
