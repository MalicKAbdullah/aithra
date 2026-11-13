import '../models/catalog.dart';
import 'calibration.dart';
import 'correctness.dart';

/// Phone and build facts that make a report comparable across devices.
class DeviceFacts {
  const DeviceFacts(this.raw);

  final Map<String, Object?> raw;

  String _s(String k) => '${raw[k] ?? '?'}';

  String get headline =>
      '${_s('manufacturer')} ${_s('model')} · Android ${_s('androidRelease')} '
      '(SDK ${_s('sdkInt')}) · SoC ${_s('socManufacturer')} ${_s('socModel')} · '
      'RAM ${((raw['totalRamMb'] as int? ?? 0) / 1024).toStringAsFixed(1)} GB';

  String get app => 'Aithra ${_s('appVersion')} (${_s('appBuild')})';
}

String fmt(double? v, {int digits = 1}) =>
    v == null ? '—' : v.toStringAsFixed(digits);

String _seconds(double? ms) =>
    ms == null ? '—' : (ms / 1000).toStringAsFixed(2);

/// Markdown report the owner pastes back: device facts, one table row per
/// model × backend, then the raw probe answers so wrong output can be seen.
String calibrationReport({
  required DeviceFacts device,
  required List<Calibration> calibrations,
  required String Function(String modelId) modelName,
  Map<String, Object?>? dbSelfTest,
}) {
  final b = StringBuffer()
    ..writeln('## Aithra performance report')
    ..writeln()
    ..writeln('- ${device.app}')
    ..writeln('- ${device.headline}')
    ..writeln('- CPU features: ${device.raw['cpuFeatures'] ?? '?'}')
    ..writeln('- Tensor NPU runtime present: ${device.raw['edgeTpuRuntime']}')
    ..writeln('- Engines: LiteRT-LM 0.19.1, llama.cpp b11935')
    ..writeln(
      '- Speed run: ~500-token prompt, $speedDecodeTokens decoded tokens, greedy',
    )
    ..writeln()
    ..writeln(
      '| Model | Backend | Load s | TTFT s | Prefill tok/s (n) | Decode tok/s (n) | Peak RSS MB | Correct | Chosen |',
    )
    ..writeln('|---|---|---|---|---|---|---|---|---|');
  for (final c in calibrations) {
    for (final r in c.results) {
      final s = r.speed;
      final backend = BackendOption.byId(r.backendId).label;
      if (r.error != null) {
        b.writeln(
          '| ${modelName(c.modelId)} | $backend | ${_seconds(r.loadMs)} '
          '| — | — | — | — | ✗ failed | |',
        );
        continue;
      }
      b.writeln(
        '| ${modelName(c.modelId)} | $backend | ${_seconds(r.loadMs)} '
        '| ${_seconds(s?.ttftMs)} '
        '| ${fmt(s?.prefillTps)} (${s?.promptTokens ?? '—'}) '
        '| ${fmt(s?.decodeTps)} (${s?.decodeTokens ?? '—'}) '
        '| ${fmt(r.peakRssMb, digits: 0)} '
        '| ${r.allCorrect ? '✓' : '✗'} ${r.correct}/${probes.length} '
        '| ${c.chosenBackend == r.backendId ? '★' : ''} |',
      );
    }
  }
  final errors = [
    for (final c in calibrations)
      for (final r in c.results)
        if (r.error != null)
          '- ${modelName(c.modelId)} / ${BackendOption.byId(r.backendId).label}: ${r.error}',
  ];
  if (errors.isNotEmpty) {
    b
      ..writeln()
      ..writeln('### Errors')
      ..writeln(errors.join('\n'));
  }
  b
    ..writeln()
    ..writeln('### Probe answers');
  for (final c in calibrations) {
    for (final r in c.results.where((r) => r.answers.isNotEmpty)) {
      final answers = [
        for (var i = 0; i < r.answers.length; i++)
          '${probes[i].expected} → "${_oneLine(r.answers[i])}"',
      ].join('; ');
      b.writeln(
        '- ${modelName(c.modelId)} / ${BackendOption.byId(r.backendId).label}: $answers',
      );
    }
    for (final r in c.results.where((r) => r.speed?.note != null)) {
      b.writeln(
        '- note ${BackendOption.byId(r.backendId).label}: ${r.speed!.note}',
      );
    }
  }
  if (dbSelfTest != null) {
    b
      ..writeln()
      ..writeln('### Storage self-test')
      ..writeln(
        '- ${dbSelfTest['messages']} messages: insert '
        '${fmt((dbSelfTest['insertMs'] as num).toDouble(), digits: 0)} ms, '
        'newest page ${fmt((dbSelfTest['pageMs'] as num).toDouble())} ms, '
        'search ${fmt((dbSelfTest['searchMs'] as num).toDouble())} ms, '
        'recall ${fmt((dbSelfTest['recallMs'] as num).toDouble())} ms',
      );
  }
  return b.toString();
}

String _oneLine(String s) {
  final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > 60 ? '${flat.substring(0, 60)}…' : flat;
}
