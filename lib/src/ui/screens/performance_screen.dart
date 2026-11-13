import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../calibration/calibration.dart';
import '../../calibration/correctness.dart';
import '../../calibration/report.dart';
import '../../engine/engine_service.dart';
import '../../models/catalog.dart';
import '../../services.dart';
import '../aithra_type.dart';
import '../widgets/section_label.dart';

/// Calibration results per model and backend, with re-run and a
/// copy-as-Markdown report for sending back.
class PerformanceScreen extends StatefulWidget {
  const PerformanceScreen({super.key});

  @override
  State<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends State<PerformanceScreen> {
  Map<String, Object?>? _device;
  Map<String, Object?>? _dbTest;
  bool _dbRunning = false;

  @override
  void initState() {
    super.initState();
    context.services.native.deviceInfo().then((d) {
      if (mounted) setState(() => _device = d);
    });
  }

  String _name(String id) => context.services.models.byId(id)?.name ?? id;

  Future<void> _copy() async {
    final s = context.services;
    final report = calibrationReport(
      device: DeviceFacts(_device ?? await s.native.deviceInfo()),
      calibrations: s.settings.calibrations.values.toList(),
      modelName: _name,
      dbSelfTest: _dbTest,
    );
    await Clipboard.setData(ClipboardData(text: report));
    HapticFeedback.selectionClick();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Results copied')));
    }
  }

  Future<void> _runDbTest() async {
    setState(() => _dbRunning = true);
    final r = await context.services.native.dbSelfTest(10000);
    if (mounted) {
      setState(() {
        _dbTest = r;
        _dbRunning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Performance')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          s.settings,
          s.assistant,
          s.models,
          s.engine,
        ]),
        builder: (context, _) {
          final active = s.assistant.activeModel;
          final tuning = s.assistant.calibrating;
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              0,
              AppSpacing.gutter,
              AppSpacing.xxl,
            ),
            children: [
              if (_device != null)
                Text(
                  DeviceFacts(_device!).headline,
                  style: AithraType.bodySmall.copyWith(color: c.textSecondary),
                ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: active == null || tuning != null
                          ? null
                          : () => s.assistant.calibrate(active),
                      icon: const Icon(Icons.replay_rounded, size: 18),
                      label: Text(
                        tuning != null
                            ? 'Testing ${tuning.label}…'
                            : 'Re-run speed test',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  OutlinedButton.icon(
                    onPressed: s.settings.calibrations.isEmpty ? null : _copy,
                    icon: const Icon(Icons.content_copy_rounded, size: 16),
                    label: const Text('Copy'),
                  ),
                ],
              ),
              if (active != null) ...[
                const SizedBox(height: AppSpacing.xs + 2),
                Text(
                  'Tests every backend for ${active.name} on this phone.',
                  style: AithraType.caption.copyWith(color: c.textTertiary),
                ),
              ],
              for (final (i, cal)
                  in s.settings.calibrations.values.indexed) ...[
                SectionLabel(_name(cal.modelId)),
                if (!cal.chosenIsCorrect)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(
                      'No backend answered every check correctly',
                      style: AithraType.caption.copyWith(color: c.negative),
                    ),
                  ),
                _Results(calibration: cal, key: ValueKey(i)),
              ],
              const SectionLabel('Diagnostics'),
              RowGroup(
                separatorIndent: AppSpacing.md,
                children: [
                  if (s.engine.lastLoad case final load?)
                    _DiagnosticRow(
                      title: 'Last model load',
                      subtitle: _loadLine(load),
                      trailing: const SizedBox.shrink(),
                    ),
                  _DiagnosticRow(
                    title: 'Performance overlay',
                    subtitle:
                        'Tokens/s, time to first token and frame times in chats',
                    onTap: () => s.settings.update(
                      (x) => x.perfOverlay = !x.perfOverlay,
                    ),
                    trailing: Switch(
                      value: s.settings.perfOverlay,
                      onChanged: (v) =>
                          s.settings.update((x) => x.perfOverlay = v),
                    ),
                  ),
                  _DiagnosticRow(
                    title: 'Storage self-test',
                    subtitle: _dbTest == null
                        ? 'Writes 10,000 test messages, times paging, search '
                              'and recall, then removes them'
                        : '10k messages · page ${(_dbTest!['pageMs'] as num).toStringAsFixed(1)} ms · '
                              'search ${(_dbTest!['searchMs'] as num).toStringAsFixed(1)} ms · '
                              'text ${(_dbTest!['textSearchMs'] as num).toStringAsFixed(0)} ms · '
                              'recall ${(_dbTest!['recallMs'] as num).toStringAsFixed(1)} ms',
                    trailing: _dbRunning
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : TextButton(
                            onPressed: _runDbTest,
                            child: const Text('Run'),
                          ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// "Gemma 4 E2B · GPU · 4.1 s · from cache", or how much cache a first load
/// on that backend built.
String _loadLine(LastLoad load) {
  final r = load.result;
  final seconds = (r.loadMs / 1000).toStringAsFixed(1);
  final cache = r.cacheWrittenMb >= 1
      ? 'first load, built ${(r.cacheWrittenMb / 1024).toStringAsFixed(2)} GB of cache'
      : load.spec.runtime == Runtime.litertlm
      ? 'from cache'
      : 'no cache for this runtime';
  return '${load.spec.name} · ${load.backend.label} · $seconds s · $cache';
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.smd,
          AppSpacing.smd,
          AppSpacing.smd,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AithraType.title.copyWith(color: c.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AithraType.bodySmall.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.smd),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// One card per model: a row per backend with its verdict and a grid of
/// metrics, so every number fits a phone without hidden columns.
class _Results extends StatelessWidget {
  const _Results({required this.calibration, super.key});

  final Calibration calibration;

  @override
  Widget build(BuildContext context) => RowGroup(
    separatorIndent: AppSpacing.md,
    children: [
      for (final r in calibration.results)
        _BackendRow(
          result: r,
          chosen: calibration.chosenBackend == r.backendId,
        ),
    ],
  );
}

class _BackendRow extends StatelessWidget {
  const _BackendRow({required this.result, required this.chosen});

  final BackendResult result;
  final bool chosen;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final r = result;
    final ok = r.allCorrect;
    final metrics = <(String, String)>[
      ('Decode', '${fmt(r.speed?.decodeTps)} t/s'),
      ('Prefill', '${fmt(r.speed?.prefillTps, digits: 0)} t/s'),
      (
        'First token',
        r.speed?.ttftMs == null
            ? '—'
            : '${(r.speed!.ttftMs! / 1000).toStringAsFixed(2)} s',
      ),
      (
        'Load',
        r.loadMs == null ? '—' : '${(r.loadMs! / 1000).toStringAsFixed(1)} s',
      ),
      ('Memory', '${fmt(r.peakRssMb, digits: 0)} MB'),
    ];
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        BackendOption.byId(r.backendId).label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AithraType.title.copyWith(
                          color: c.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (chosen) ...[
                      const SizedBox(width: AppSpacing.sm),
                      _Badge(
                        icon: Icons.star_rounded,
                        label: 'Chosen',
                        color: c.accent,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _Badge(
                icon: r.error != null
                    ? Icons.error_outline_rounded
                    : ok
                    ? Icons.check_circle_rounded
                    : Icons.cancel_rounded,
                label: r.error != null
                    ? 'Failed'
                    : '${r.correct}/${probes.length} correct',
                color: ok ? c.positive : c.negative,
              ),
            ],
          ),
          if (r.error == null) ...[
            const SizedBox(height: AppSpacing.smd),
            LayoutBuilder(
              builder: (context, box) {
                final cell = (box.maxWidth - 2 * AppSpacing.sm) / 3;
                return Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final (label, value) in metrics)
                      SizedBox(
                        width: cell,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: AithraType.caption.copyWith(
                                color: c.textTertiary,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              value,
                              style: AithraType.number.copyWith(
                                color: c.textPrimary,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ] else ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              r.error!,
              style: AithraType.bodySmall.copyWith(color: c.negative),
            ),
          ],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: AithraType.caption.copyWith(
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );
}
