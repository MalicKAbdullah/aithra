import 'dart:convert';
import 'dart:math' as math;

import 'expr.dart';

/// What a ```plot or ```chart fence in a reply asks Aithra to draw.
sealed class ChartSpec {
  const ChartSpec({required this.title});

  final String title;

  /// Fence languages that hold a spec.
  static const languages = {'plot', 'chart'};

  /// Reads the JSON in a [language] fence. Throws a [FormatException] that
  /// says what is wrong when the spec cannot be drawn.
  static ChartSpec parse(String language, String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      throw const FormatException('The spec is not valid JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const FormatException('The spec must be a JSON object');
    }
    return language == 'plot' ? PlotSpec._from(json) : DataChart._from(json);
  }
}

/// Graphs of functions of x: `{"fn": ["sin(x)", "x^2/4"], "x": [-6.28, 6.28]}`.
class PlotSpec extends ChartSpec {
  PlotSpec({
    required super.title,
    required this.functions,
    required this.sources,
    required this.xMin,
    required this.xMax,
    this.yMin,
    this.yMax,
  });

  factory PlotSpec._from(Map<String, Object?> json) {
    final fn = json['fn'];
    final sources = switch (fn) {
      final String s => [s],
      final List<Object?> l when l.isNotEmpty && l.every((e) => e is String) =>
        l.cast<String>(),
      _ => throw const FormatException(
        '"fn" must be a formula or a list of them',
      ),
    };
    if (sources.length > 6) {
      throw const FormatException('At most 6 functions fit one plot');
    }
    final functions = <Fx>[];
    for (final s in sources) {
      final body = s.replaceFirst(RegExp(r'^\s*(y|f\(x\))\s*='), '');
      try {
        functions.add(compileExpr(body));
      } on FormatException catch (e) {
        throw FormatException('Cannot read "$s": ${e.message}');
      }
    }
    final (xMin, xMax) = _range(json['x'], 'x') ?? (-10.0, 10.0);
    final y = _range(json['y'], 'y');
    return PlotSpec(
      title: _string(json['title']),
      functions: functions,
      sources: sources,
      xMin: xMin,
      xMax: xMax,
      yMin: y?.$1,
      yMax: y?.$2,
    );
  }

  final List<Fx> functions;

  /// The formulas as written, which name each curve.
  final List<String> sources;
  final double xMin;
  final double xMax;
  final double? yMin;
  final double? yMax;
}

enum ChartType { bar, line, pie, scatter }

class Series {
  const Series(this.name, this.values);
  final String name;

  /// Bar, line and pie values, one per label; scatter points as (x, y).
  final List<(double, double)> values;
}

/// Charts of data: `{"type": "bar", "labels": [...], "series": [...]}`.
class DataChart extends ChartSpec {
  const DataChart({
    required super.title,
    required this.type,
    required this.labels,
    required this.series,
  });

  factory DataChart._from(Map<String, Object?> json) {
    final type = ChartType.values
        .where((t) => t.name == json['type'])
        .firstOrNull;
    if (type == null) {
      throw const FormatException('"type" must be bar, line, pie or scatter');
    }
    final rawLabels = json['labels'] ?? const <Object?>[];
    if (rawLabels is! List<Object?>) {
      throw const FormatException('"labels" must be a list');
    }
    final labels = [for (final l in rawLabels) '${l ?? ''}'];
    final rawSeries = json['series'];
    if (rawSeries is! List<Object?> || rawSeries.isEmpty) {
      throw const FormatException('"series" must be a non-empty list');
    }
    if (rawSeries.length > 6) {
      throw const FormatException('At most 6 series fit one chart');
    }
    final series = <Series>[];
    for (final (i, s) in rawSeries.indexed) {
      if (s is! Map<String, Object?>) {
        throw const FormatException('Each series must be an object');
      }
      final data = s['data'];
      if (data is! List<Object?> || data.isEmpty) {
        throw FormatException('Series ${i + 1} has no "data"');
      }
      final values = <(double, double)>[];
      for (final (j, d) in data.indexed) {
        if (type == ChartType.scatter) {
          if (d is List<Object?> && d.length == 2 && d.every((v) => v is num)) {
            values.add(((d[0]! as num).toDouble(), (d[1]! as num).toDouble()));
            continue;
          }
          throw FormatException('Scatter points must be [x, y] pairs');
        }
        if (d is! num || !d.isFinite) {
          throw FormatException(
            'Series ${i + 1} has a value that is not a number',
          );
        }
        values.add((j.toDouble(), d.toDouble()));
      }
      if (type != ChartType.scatter && values.length != labels.length) {
        throw FormatException(
          'Series ${i + 1} has ${values.length} values for '
          '${labels.length} labels',
        );
      }
      series.add(Series(_string(s['name']), values));
    }
    if (type == ChartType.pie) {
      if (series.length != 1) {
        throw const FormatException('A pie chart takes one series');
      }
      if (series.single.values.any((v) => v.$2 < 0) ||
          series.single.values.every((v) => v.$2 == 0)) {
        throw const FormatException('Pie values must be positive');
      }
    }
    return DataChart(
      title: _string(json['title']),
      type: type,
      labels: labels,
      series: series,
    );
  }

  final ChartType type;
  final List<String> labels;
  final List<Series> series;

  /// The data as tab-separated values, which spreadsheets paste as cells.
  String tsv() {
    if (type == ChartType.scatter) {
      return [
        for (final s in series) ...[
          for (final p in s.values) '${s.name}\t${_num(p.$1)}\t${_num(p.$2)}',
        ],
      ].join('\n');
    }
    return [
      ['', for (final s in series) s.name].join('\t'),
      for (var i = 0; i < labels.length; i++)
        [labels[i], for (final s in series) _num(s.values[i].$2)].join('\t'),
    ].join('\n');
  }
}

String _num(double v) =>
    v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt().toString() : '$v';

String _string(Object? v) => v is String ? v.trim() : '';

(double, double)? _range(Object? v, String name) {
  if (v == null) return null;
  if (v is List<Object?> &&
      v.length == 2 &&
      v.every((e) => e is num && e.isFinite)) {
    final a = (v[0]! as num).toDouble(), b = (v[1]! as num).toDouble();
    if (a < b) return (a, b);
  }
  throw FormatException('"$name" must be [min, max] with min < max');
}

/// Axis ticks on the 1-2-5 ladder: about [count] round values spanning
/// [lo]..[hi].
({double start, double step, List<double> ticks}) niceTicks(
  double lo,
  double hi, {
  int count = 5,
}) {
  final span = hi - lo;
  final raw = span / count;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final step =
      (norm < 1.5
          ? 1
          : norm < 3
          ? 2
          : norm < 7
          ? 5
          : 10) *
      mag;
  final start = (lo / step).ceil() * step;
  return (
    start: start,
    step: step,
    ticks: [
      for (var t = start; t <= hi + step * 1e-9; t += step)
        (t / step).round() * step,
    ],
  );
}

/// [v] for an axis whose ticks are [step] apart: as few decimals as the
/// step needs, with a true minus sign.
String tickLabel(double v, double step) {
  final decimals = step >= 1
      ? 0
      : (-(math.log(step) / math.ln10).floor()).clamp(0, 10);
  final abs = v.abs();
  final String s;
  if (abs >= 1e6 || (abs > 0 && abs < 1e-4)) {
    s = v.toStringAsExponential(1);
  } else {
    s = v.toStringAsFixed(decimals);
  }
  return s.startsWith('-') && double.parse(s) != 0
      ? '−${s.substring(1)}'
      : s.replaceFirst(RegExp(r'^-'), '');
}
