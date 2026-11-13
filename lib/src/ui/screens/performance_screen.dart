import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../calibration/calibration.dart';
import '../../calibration/report.dart';
import '../../models/catalog.dart';
import '../../services.dart';

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
        listenable: Listenable.merge([s.settings, s.assistant, s.models]),
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
                  style: AppTextStyles.bodySmall.copyWith(
                    color: c.textSecondary,
                  ),
                ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: s.settings.calibrations.isEmpty ? null : _copy,
                icon: const Icon(Icons.content_copy_rounded),
                label: const Text('Copy results'),
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: active == null || tuning != null
                    ? null
                    : () => s.assistant.calibrate(active),
                icon: const Icon(Icons.replay_rounded),
                label: Text(
                  tuning != null
                      ? 'Testing ${tuning.label}…'
                      : 'Re-run speed test${active == null ? '' : ' (${active.name})'}',
                ),
              ),
              for (final cal in s.settings.calibrations.values) ...[
                SectionHeader(
                  title: _name(cal.modelId),
                  subtitle: cal.chosenIsCorrect
                      ? null
                      : 'No backend answered every check correctly',
                ),
                _ResultsTable(calibration: cal),
              ],
              const SectionHeader(title: 'Diagnostics'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Performance overlay'),
                subtitle: const Text(
                  'Tokens/s, time to first token and frame times in chats',
                ),
                value: s.settings.perfOverlay,
                onChanged: (v) => s.settings.update((x) => x.perfOverlay = v),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Storage self-test'),
                subtitle: Text(
                  _dbTest == null
                      ? 'Writes 10,000 test messages, times paging, search and recall, then removes them'
                      : '10k messages · page ${(_dbTest!['pageMs'] as num).toStringAsFixed(1)} ms · '
                            'search ${(_dbTest!['searchMs'] as num).toStringAsFixed(1)} ms · '
                            'recall ${(_dbTest!['recallMs'] as num).toStringAsFixed(1)} ms',
                ),
                trailing: _dbRunning
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: _runDbTest,
                        child: const Text('Run'),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ResultsTable extends StatelessWidget {
  const _ResultsTable({required this.calibration});

  final Calibration calibration;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final style = AppTextStyles.numberSmall.copyWith(color: c.textPrimary);
    final head = AppTextStyles.caption.copyWith(color: c.textTertiary);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 16,
        horizontalMargin: 0,
        headingTextStyle: head,
        dataTextStyle: style,
        columns: const [
          DataColumn(label: Text('Backend')),
          DataColumn(label: Text('Load s'), numeric: true),
          DataColumn(label: Text('TTFT s'), numeric: true),
          DataColumn(label: Text('Prefill t/s'), numeric: true),
          DataColumn(label: Text('Decode t/s'), numeric: true),
          DataColumn(label: Text('RSS MB'), numeric: true),
          DataColumn(label: Text('Correct')),
        ],
        rows: [
          for (final r in calibration.results)
            DataRow(
              cells: [
                DataCell(
                  Text(
                    '${calibration.chosenBackend == r.backendId ? '★ ' : ''}${BackendOption.byId(r.backendId).label}',
                  ),
                ),
                DataCell(
                  Text(
                    r.loadMs == null
                        ? '—'
                        : (r.loadMs! / 1000).toStringAsFixed(1),
                  ),
                ),
                DataCell(
                  Text(
                    r.speed?.ttftMs == null
                        ? '—'
                        : (r.speed!.ttftMs! / 1000).toStringAsFixed(2),
                  ),
                ),
                DataCell(Text(fmt(r.speed?.prefillTps))),
                DataCell(Text(fmt(r.speed?.decodeTps))),
                DataCell(Text(fmt(r.peakRssMb, digits: 0))),
                DataCell(
                  Text(
                    r.error != null
                        ? 'failed'
                        : '${r.allCorrect ? '✓' : '✗'} ${r.correct}/3',
                    style: TextStyle(
                      color: r.allCorrect ? c.positive : c.negative,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
