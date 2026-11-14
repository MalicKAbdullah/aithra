import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../chat/chart_spec.dart';
import '../../services.dart';
import '../aithra_type.dart';
import 'markdown_view.dart';

/// A ```plot or ```chart fence: drawn once it has closed, a "Drawing…"
/// placeholder while it streams, and the fence's source with a caption
/// when the spec cannot be drawn.
class ChartBlock extends StatelessWidget {
  const ChartBlock({
    required this.language,
    required this.source,
    required this.closed,
    super.key,
  });

  final String language;
  final String source;
  final bool closed;

  static final LinkedHashMap<String, Object> _specs = LinkedHashMap();

  /// The parsed spec, or the [FormatException] saying why there is none.
  static Object _parse(String language, String source) {
    final key = '$language\u0000$source';
    final hit = _specs.remove(key);
    if (hit != null) return _specs[key] = hit;
    if (_specs.length >= 64) _specs.remove(_specs.keys.first);
    try {
      return _specs[key] = ChartSpec.parse(language, source);
    } on FormatException catch (e) {
      return _specs[key] = e;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!closed) return const _Drawing();
    return switch (_parse(language, source)) {
      final ChartSpec spec => ChartCard(spec: spec),
      final FormatException e => _Undrawable(
        language: language,
        source: source,
        reason: e.message,
      ),
      _ => throw StateError('_parse returns a spec or its error'),
    };
  }
}

class _Drawing extends StatelessWidget {
  const _Drawing();

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: c.hairline),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.show_chart_rounded, size: 18, color: c.textTertiary),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Drawing…',
                style: AithraType.bodySmall.copyWith(color: c.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Undrawable extends StatelessWidget {
  const _Undrawable({
    required this.language,
    required this.source,
    required this.reason,
  });

  final String language;
  final String source;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CodeBlock(language: language, code: source),
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs + 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  Icons.info_outline_rounded,
                  size: 14,
                  color: c.textTertiary,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "Couldn't draw this · $reason",
                  style: AithraType.caption.copyWith(color: c.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A drawn chart in a card: a header with its title and actions, the chart
/// at 16:10 and, for several series, a legend. Tapping or dragging over the
/// chart reads values off it.
class ChartCard extends StatefulWidget {
  const ChartCard({required this.spec, super.key});

  final ChartSpec spec;

  @override
  State<ChartCard> createState() => _ChartCardState();
}

class _ChartCardState extends State<ChartCard> {
  final _boundary = GlobalKey();

  /// Where the reader is pointing, in chart coordinates.
  final _probe = ValueNotifier<Offset?>(null);

  _Chart? _chart;

  @override
  void didUpdateWidget(ChartCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.spec, widget.spec)) {
      _chart = null;
      _probe.value = null;
    }
  }

  @override
  void dispose() {
    _probe.dispose();
    super.dispose();
  }

  _Chart _chartFor(Size size, SuiteColors c, TextScaler scaler) {
    final chart = _chart;
    if (chart != null &&
        chart.size == size &&
        identical(chart.colors, c) &&
        chart.scaler == scaler) {
      return chart;
    }
    return _chart = _Chart.build(widget.spec, size, c, scaler);
  }

  String get _name {
    final spec = widget.spec;
    if (spec.title.isNotEmpty) return spec.title;
    return spec is PlotSpec ? 'Plot' : 'Chart';
  }

  Future<Uint8List> _png() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  Future<void> _copyData() async {
    final spec = widget.spec;
    final text = switch (spec) {
      PlotSpec() => [
        for (final s in spec.sources) 'y = $s',
        'x from ${spec.xMin} to ${spec.xMax}',
      ].join('\n'),
      DataChart() => spec.tsv(),
    };
    await Clipboard.setData(ClipboardData(text: text));
    await HapticFeedback.selectionClick();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Data copied')));
  }

  Future<void> _export({required bool save}) async {
    final native = context.services.native;
    final messenger = ScaffoldMessenger.of(context);
    final png = await _png();
    if (save) {
      await native.saveImage(png, _name);
      messenger.showSnackBar(
        const SnackBar(content: Text('Saved to Pictures/Aithra')),
      );
    } else {
      await native.shareImage(png, _name);
    }
  }

  void _point(Offset local) => _probe.value = local;

  /// A tap where the read-out already is puts it away.
  void _tap(Offset local) {
    final shown = _probe.value;
    _probe.value = shown != null && (shown - local).distance < 24
        ? null
        : local;
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark
        ? Color.alphaBlend(const Color(0x0AFFFFFF), c.surface)
        : c.surface;
    final spec = widget.spec;
    Widget action(IconData icon, String tip, VoidCallback onTap) => IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: tip,
      iconSize: 17,
      icon: Icon(icon),
      onPressed: onTap,
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: c.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpacing.smd),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AithraType.labelStrong.copyWith(
                        color: c.textPrimary,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                  action(Icons.content_copy_rounded, 'Copy data', _copyData),
                  action(
                    Icons.ios_share_rounded,
                    'Share image',
                    () => _export(save: false),
                  ),
                  action(
                    Icons.download_rounded,
                    'Save image',
                    () => _export(save: true),
                  ),
                ],
              ),
            ),
          ),
          RepaintBoundary(
            key: _boundary,
            child: ColoredBox(
              color: bg,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.smd,
                  AppSpacing.smd,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 10,
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final chart = _chartFor(box.biggest, c, scaler);
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (d) => _tap(d.localPosition),
                            onHorizontalDragStart: (d) =>
                                _point(d.localPosition),
                            onHorizontalDragUpdate: (d) =>
                                _point(d.localPosition),
                            child: Semantics(
                              label: chart.description,
                              child: CustomPaint(
                                painter: _ChartPainter(chart, bg),
                                foregroundPainter: _ProbePainter(
                                  chart,
                                  _probe,
                                  bg,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (_legend(spec) case final entries?)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: AppSpacing.sm,
                          left: AppSpacing.xs,
                        ),
                        child: Wrap(
                          spacing: AppSpacing.md,
                          runSpacing: AppSpacing.xs,
                          children: [
                            for (final (i, e) in entries.indexed)
                              _LegendEntry(color: c.chart[i], label: e),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Legend labels when identity needs one: every pie slice, and two or
  /// more series or curves.
  static List<String>? _legend(ChartSpec spec) => switch (spec) {
    PlotSpec(:final sources) when sources.length > 1 => [
      for (final s in sources) 'y = $s',
    ],
    DataChart(type: ChartType.pie) => _PieSlice.of(spec).map((s) {
      return '${s.label} · ${_percent(s.share)}';
    }).toList(),
    DataChart(:final series) when series.length > 1 => [
      for (final (i, s) in series.indexed)
        s.name.isEmpty ? 'Series ${i + 1}' : s.name,
    ],
    _ => null,
  };
}

String _percent(double share) {
  final p = share * 100;
  return p < 10 && p != p.roundToDouble()
      ? '${p.toStringAsFixed(1)}%'
      : '${p.round()}%';
}

class _LegendEntry extends StatelessWidget {
  const _LegendEntry({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: AithraType.caption.copyWith(color: c.textSecondary),
          ),
        ),
      ],
    );
  }
}

// -- Geometry -----------------------------------------------------------------

class _PieSlice {
  const _PieSlice(this.label, this.value, this.share);
  final String label;
  final double value;
  final double share;

  /// One slice per label, at most as many as there are series colours: the
  /// smallest fold into "Other".
  static List<_PieSlice> of(DataChart chart) {
    final values = chart.series.single.values;
    final entries = [
      for (var i = 0; i < chart.labels.length; i++)
        (chart.labels[i], values[i].$2),
    ];
    const max = 6;
    if (entries.length > max) {
      entries.sort((a, b) => b.$2.compareTo(a.$2));
      final rest = entries.sublist(max - 1).fold(0.0, (s, e) => s + e.$2);
      entries
        ..removeRange(max - 1, entries.length)
        ..add(('Other', rest));
    }
    final total = entries.fold(0.0, (s, e) => s + e.$2);
    return [for (final (l, v) in entries) _PieSlice(l, v, v / total)];
  }
}

/// Everything about one chart at one size: axes, scales, sampled curves.
/// Built once per size and theme and shared by the chart and the probe.
class _Chart {
  _Chart._(this.spec, this.size, this.colors, this.scaler);

  factory _Chart.build(
    ChartSpec spec,
    Size size,
    SuiteColors colors,
    TextScaler scaler,
  ) => _Chart._(spec, size, colors, scaler).._layout();

  final ChartSpec spec;
  final Size size;
  final SuiteColors colors;
  final TextScaler scaler;

  late Rect plot;
  double xMin = 0, xMax = 1, yMin = 0, yMax = 1;
  List<double> xTicks = const [];
  double xStep = 1;
  List<double> yTicks = const [];
  double yStep = 1;

  /// Curve samples for a plot: one x per device pixel column, and per
  /// function its y values (NaN where it is undefined).
  Float64List xs = Float64List(0);
  List<Float64List> ys = const [];
  bool empty = false;

  List<_PieSlice> slices = const [];

  TextStyle get tickStyle => AithraType.caption.copyWith(
    color: colors.textTertiary,
    fontSize: 11,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  bool get categorical =>
      spec is DataChart &&
      ((spec as DataChart).type == ChartType.bar ||
          (spec as DataChart).type == ChartType.line);

  String get description => switch (spec) {
    PlotSpec(:final sources) => 'Graph of ${sources.join(', ')}',
    DataChart(:final type, :final title) =>
      '${type.name} chart${title.isEmpty ? '' : ': $title'}',
  };

  double sx(double x) => plot.left + (x - xMin) / (xMax - xMin) * plot.width;
  double sy(double y) => plot.bottom - (y - yMin) / (yMax - yMin) * plot.height;
  double dataX(double px) =>
      xMin + (px - plot.left) / plot.width * (xMax - xMin);

  TextPainter text(String s, TextStyle style, {double? maxWidth}) =>
      TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: maxWidth ?? double.infinity);

  void _layout() {
    final spec = this.spec;
    if (spec is DataChart && spec.type == ChartType.pie) {
      slices = _PieSlice.of(spec);
      plot = Offset.zero & size;
      return;
    }
    switch (spec) {
      case PlotSpec():
        xMin = spec.xMin;
        xMax = spec.xMax;
        _sample(spec, (size.width * 2).round().clamp(64, 1200));
      case DataChart(type: ChartType.scatter):
        final points = [for (final s in spec.series) ...s.values];
        final (x0, x1) = _padded(points.map((p) => p.$1));
        final (y0, y1) = _padded(points.map((p) => p.$2));
        xMin = x0;
        xMax = x1;
        yMin = y0;
        yMax = y1;
      case DataChart():
        xMin = -0.5;
        xMax = spec.labels.length - 0.5;
        final values = [
          for (final s in spec.series) ...s.values.map((v) => v.$2),
        ];
        final lo = math.min(0.0, values.reduce(math.min));
        final hi = math.max(0.0, values.reduce(math.max));
        yMin = lo;
        yMax = hi == lo ? lo + 1 : hi;
        if (spec.type == ChartType.line) {
          final (y0, y1) = _padded(values);
          yMin = y0;
          yMax = y1;
        }
    }
    final tick = text('0', tickStyle);
    final lineHeight = tick.height;
    tick.dispose();
    // Ticks first, so the y labels' widest entry sets the left margin.
    final y = niceTicks(
      yMin,
      yMax,
      count: (size.height / (lineHeight * 3.2)).floor().clamp(2, 6),
    );
    yStep = y.step;
    yTicks = y.ticks;
    if (spec is DataChart && spec.type == ChartType.bar) {
      // Bars rise from zero and end at a tick, so the top is labelled.
      yMax = math.max(yMax, yTicks.last + (yTicks.last < yMax ? yStep : 0));
      yTicks = niceTicks(yMin, yMax, count: yTicks.length).ticks;
    }
    var labelWidth = 0.0;
    for (final t in yTicks) {
      final p = text(tickLabel(t, yStep), tickStyle);
      labelWidth = math.max(labelWidth, p.width);
      p.dispose();
    }
    plot = Rect.fromLTRB(
      labelWidth + 8,
      lineHeight / 2,
      size.width - 4,
      size.height - lineHeight - 6,
    );
    if (!categorical) {
      final x = niceTicks(
        xMin,
        xMax,
        count: (plot.width / 64).floor().clamp(2, 8),
      );
      xStep = x.step;
      xTicks = x.ticks;
    }
  }

  /// [values]' range with a little air above and below; one value gets a
  /// unit of room each side.
  static (double, double) _padded(Iterable<double> values) {
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final v in values) {
      lo = math.min(lo, v);
      hi = math.max(hi, v);
    }
    if (hi - lo < 1e-12) return (lo - 1, hi + 1);
    final pad = (hi - lo) * 0.06;
    return (lo - pad, hi + pad);
  }

  void _sample(PlotSpec spec, int n) {
    xs = Float64List(n);
    for (var i = 0; i < n; i++) {
      xs[i] = xMin + (xMax - xMin) * i / (n - 1);
    }
    ys = [
      for (final f in spec.functions)
        Float64List.fromList([for (final x in xs) f(x)]),
    ];
    if (spec.yMin != null) {
      yMin = spec.yMin!;
      yMax = spec.yMax!;
      return;
    }
    final finite = [
      for (final s in ys)
        for (final v in s)
          if (v.isFinite) v,
    ]..sort();
    if (finite.isEmpty) {
      empty = true;
      yMin = -1;
      yMax = 1;
      return;
    }
    // Poles (tan x, 1/x) shoot off to huge values on a sample or two; the
    // range follows the bulk of the curve, and reaches the extremes only
    // when they are near it.
    double at(double q) => finite[((finite.length - 1) * q).round()];
    var lo = at(0.02), hi = at(0.98);
    final span = math.max(hi - lo, 1e-9);
    if (lo - finite.first < span * 0.5) lo = finite.first;
    if (finite.last - hi < span * 0.5) hi = finite.last;
    final (y0, y1) = _padded([lo, hi]);
    yMin = y0;
    yMax = y1;
  }
}

// -- Painting -----------------------------------------------------------------

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.chart, this.background);

  final _Chart chart;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final spec = chart.spec;
    if (spec is DataChart && spec.type == ChartType.pie) {
      _pie(canvas);
      return;
    }
    _axes(canvas);
    canvas.save();
    canvas.clipRect(chart.plot.inflate(1));
    switch (spec) {
      case PlotSpec():
        _curves(canvas);
      case DataChart(type: ChartType.bar):
        _bars(canvas, spec);
      case DataChart(type: ChartType.line):
        _lines(canvas, spec);
      case DataChart():
        _scatter(canvas, spec);
    }
    canvas.restore();
    if (chart.empty) {
      final p = chart.text(
        'Nothing to draw in this range',
        AithraType.bodySmall.copyWith(color: chart.colors.textTertiary),
      );
      p.paint(canvas, chart.plot.center - Offset(p.width / 2, p.height / 2));
      p.dispose();
    }
  }

  void _axes(Canvas canvas) {
    final c = chart.colors;
    final plot = chart.plot;
    final grid = Paint()
      ..color = c.hairline
      ..strokeWidth = 1;
    final axis = Paint()
      ..color = c.border
      ..strokeWidth = 1;
    for (final t in chart.yTicks) {
      final y = chart.sy(t).roundToDouble() + 0.5;
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        t == 0 ? axis : grid,
      );
      final p = chart.text(tickLabel(t, chart.yStep), chart.tickStyle);
      p.paint(canvas, Offset(plot.left - 6 - p.width, y - p.height / 2));
      p.dispose();
    }
    final labelTop = plot.bottom + 4;
    final spec = chart.spec;
    if (chart.categorical) {
      final labels = (spec as DataChart).labels;
      final slot = plot.width / labels.length;
      // Every label when they fit, otherwise every k-th.
      var widest = 0.0;
      for (final l in labels) {
        final p = chart.text(l, chart.tickStyle);
        widest = math.max(widest, p.width);
        p.dispose();
      }
      final every = math.max(1, ((widest + 6) / slot).ceil());
      final maxWidth = slot * every - 4;
      for (var i = 0; i < labels.length; i += every) {
        final p = chart.text(labels[i], chart.tickStyle, maxWidth: maxWidth);
        final x = chart.sx(i.toDouble());
        p.paint(canvas, Offset(x - p.width / 2, labelTop));
        p.dispose();
      }
      return;
    }
    for (final t in chart.xTicks) {
      final x = chart.sx(t).roundToDouble() + 0.5;
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        t == 0 ? axis : grid,
      );
      final p = chart.text(tickLabel(t, chart.xStep), chart.tickStyle);
      final left = (x - p.width / 2).clamp(0.0, chart.size.width - p.width);
      p.paint(canvas, Offset(left, labelTop));
      p.dispose();
    }
  }

  Paint _stroke(Color color) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;

  void _curves(Canvas canvas) {
    final top = chart.plot.top, bottom = chart.plot.bottom;
    for (final (i, ys) in chart.ys.indexed) {
      final path = Path();
      var pen = false;
      double? prev;
      for (var k = 0; k < ys.length; k++) {
        final v = ys[k];
        if (!v.isFinite) {
          pen = false;
          prev = null;
          continue;
        }
        final py = chart.sy(v);
        final px = chart.sx(chart.xs[k]);
        // Leaping from beyond one edge to beyond the other between two
        // neighbouring samples is a pole, not a steep stretch of curve.
        final pole =
            prev != null &&
            ((prev < top && py > bottom) || (prev > bottom && py < top));
        if (!pen || pole) {
          path.moveTo(px, py.clamp(top - 4000, bottom + 4000));
          pen = true;
        } else {
          path.lineTo(px, py.clamp(top - 4000, bottom + 4000));
        }
        prev = py;
      }
      canvas.drawPath(path, _stroke(chart.colors.chart[i]));
    }
  }

  void _bars(Canvas canvas, DataChart spec) {
    final n = spec.series.length;
    final slot = chart.plot.width / spec.labels.length;
    final group = slot * (n == 1 ? 0.62 : 0.78);
    const gap = 2.0;
    final width = math.max(1.0, (group - gap * (n - 1)) / n);
    final zero = chart.sy(0);
    for (var i = 0; i < spec.labels.length; i++) {
      final left = chart.sx(i.toDouble()) - group / 2;
      for (var s = 0; s < n; s++) {
        final v = spec.series[s].values[i].$2;
        final x = left + s * (width + gap);
        final y = chart.sy(v);
        final r = Radius.circular(math.min(4, width / 2));
        final rect = Rect.fromLTRB(
          x,
          math.min(y, zero),
          x + width,
          math.max(y, zero),
        );
        // Rounded at the data end only; the baseline end stays square.
        canvas.drawRRect(
          v >= 0
              ? RRect.fromRectAndCorners(rect, topLeft: r, topRight: r)
              : RRect.fromRectAndCorners(rect, bottomLeft: r, bottomRight: r),
          Paint()..color = chart.colors.chart[s],
        );
      }
    }
  }

  void _lines(Canvas canvas, DataChart spec) {
    final markers = spec.labels.length <= 24;
    for (final (s, series) in spec.series.indexed) {
      final color = chart.colors.chart[s];
      final path = Path();
      for (final (i, v) in series.values.indexed) {
        final p = Offset(chart.sx(i.toDouble()), chart.sy(v.$2));
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, _stroke(color));
      if (!markers) continue;
      for (final (i, v) in series.values.indexed) {
        _dot(
          canvas,
          Offset(chart.sx(i.toDouble()), chart.sy(v.$2)),
          color,
          3.5,
        );
      }
    }
  }

  void _scatter(Canvas canvas, DataChart spec) {
    for (final (s, series) in spec.series.indexed) {
      for (final p in series.values) {
        _dot(
          canvas,
          Offset(chart.sx(p.$1), chart.sy(p.$2)),
          chart.colors.chart[s],
          4,
        );
      }
    }
  }

  /// A marker with a ring in the card's colour, so overlapping marks stay
  /// apart.
  void _dot(Canvas canvas, Offset at, Color color, double radius) {
    canvas
      ..drawCircle(at, radius + 1.5, Paint()..color = background)
      ..drawCircle(at, radius, Paint()..color = color);
  }

  void _pie(Canvas canvas) {
    final size = chart.size;
    final radius = math.min(size.width, size.height) / 2 - 4;
    final center = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: center, radius: radius);
    var start = -math.pi / 2;
    final gap = Paint()
      ..color = background
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final (i, s) in chart.slices.indexed) {
      final sweep = s.share * 2 * math.pi;
      canvas.drawArc(
        rect,
        start,
        sweep,
        true,
        Paint()..color = chart.colors.chart[i],
      );
      start += sweep;
    }
    if (chart.slices.length > 1) {
      start = -math.pi / 2;
      for (final s in chart.slices) {
        canvas.drawLine(
          center,
          center + Offset(math.cos(start), math.sin(start)) * radius,
          gap,
        );
        start += s.share * 2 * math.pi;
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      !identical(old.chart, chart) || old.background != background;
}

/// The value read-out under the reader's finger: a crosshair and a label
/// listing each series at that point.
class _ProbePainter extends CustomPainter {
  _ProbePainter(this.chart, this.probe, this.background)
    : super(repaint: probe);

  final _Chart chart;
  final ValueNotifier<Offset?> probe;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final at = probe.value;
    if (at == null || chart.empty) return;
    final spec = chart.spec;
    final c = chart.colors;
    final rows = <(Color?, String)>[];
    Offset? anchor;
    final line = Paint()
      ..color = c.textTertiary
      ..strokeWidth = 1;
    switch (spec) {
      case PlotSpec():
        if (!chart.plot.contains(at)) return;
        final x = chart.dataX(at.dx);
        canvas.drawLine(
          Offset(at.dx, chart.plot.top),
          Offset(at.dx, chart.plot.bottom),
          line,
        );
        rows.add((null, 'x = ${_value(x)}'));
        for (final (i, f) in spec.functions.indexed) {
          final y = f(x);
          rows.add((c.chart[i], '${spec.sources[i]} = ${_value(y)}'));
          if (y.isFinite && y >= chart.yMin && y <= chart.yMax) {
            _ring(canvas, Offset(at.dx, chart.sy(y)), c.chart[i]);
          }
        }
        anchor = Offset(at.dx, chart.plot.top);
      case DataChart(type: ChartType.pie):
        final center = size.center(Offset.zero);
        final d = at - center;
        if (d.distance > math.min(size.width, size.height) / 2) return;
        var angle = math.atan2(d.dy, d.dx) + math.pi / 2;
        if (angle < 0) angle += 2 * math.pi;
        var acc = 0.0;
        for (final (i, s) in chart.slices.indexed) {
          acc += s.share * 2 * math.pi;
          if (angle <= acc) {
            rows.add((
              c.chart[i],
              '${s.label}: ${_value(s.value)} · ${_percent(s.share)}',
            ));
            break;
          }
        }
        anchor = at;
      case DataChart(type: ChartType.scatter):
        (Series, (double, double), int)? best;
        var bestD = 28.0;
        for (final (i, s) in spec.series.indexed) {
          for (final p in s.values) {
            final d = (Offset(chart.sx(p.$1), chart.sy(p.$2)) - at).distance;
            if (d < bestD) {
              bestD = d;
              best = (s, p, i);
            }
          }
        }
        if (best == null) return;
        final (s, p, i) = best;
        final point = Offset(chart.sx(p.$1), chart.sy(p.$2));
        _ring(canvas, point, c.chart[i]);
        rows.add((
          c.chart[i],
          '${s.name.isEmpty ? '' : '${s.name}: '}(${_value(p.$1)}, ${_value(p.$2)})',
        ));
        anchor = point;
      case DataChart(:final labels, :final series):
        final i = chart.dataX(at.dx).round().clamp(0, labels.length - 1);
        final x = chart.sx(i.toDouble());
        canvas.drawLine(
          Offset(x, chart.plot.top),
          Offset(x, chart.plot.bottom),
          line,
        );
        if (labels[i].isNotEmpty) rows.add((null, labels[i]));
        for (final (k, s) in series.indexed) {
          final v = s.values[i].$2;
          rows.add((
            c.chart[k],
            '${s.name.isEmpty ? '' : '${s.name}: '}${_value(v)}',
          ));
          if (spec.type == ChartType.line) {
            _ring(canvas, Offset(x, chart.sy(v)), c.chart[k]);
          }
        }
        anchor = Offset(x, chart.plot.top);
    }
    _label(canvas, size, anchor, rows);
  }

  void _ring(Canvas canvas, Offset at, Color color) {
    canvas
      ..drawCircle(at, 5.5, Paint()..color = background)
      ..drawCircle(
        at,
        4.5,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
  }

  void _label(
    Canvas canvas,
    Size size,
    Offset anchor,
    List<(Color?, String)> rows,
  ) {
    final c = chart.colors;
    final style = AithraType.caption.copyWith(
      color: c.textPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final painters = [
      for (final r in rows) chart.text(r.$2, style, maxWidth: size.width * 0.7),
    ];
    const pad = 8.0, swatch = 8.0, rowGap = 2.0;
    final width =
        painters.fold<double>(0.0, (w, p) => math.max(w, p.width)) +
        pad * 2 +
        (rows.any((r) => r.$1 != null) ? swatch + 6 : 0.0);
    final height =
        painters.fold<double>(0.0, (h, p) => h + p.height) +
        rowGap * (painters.length - 1) +
        pad * 2;
    var left = anchor.dx + 10;
    if (left + width > size.width) left = anchor.dx - 10 - width;
    left = left.clamp(0.0, math.max(0.0, size.width - width));
    final top = anchor.dy
        .clamp(0.0, math.max(0.0, size.height - height))
        .toDouble();
    final box = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, width, height),
      const Radius.circular(8),
    );
    canvas
      ..drawRRect(box, Paint()..color = c.surface)
      ..drawRRect(
        box,
        Paint()
          ..color = c.border
          ..style = PaintingStyle.stroke,
      );
    var y = top + pad;
    final indent = rows.any((r) => r.$1 != null) ? swatch + 6 : 0.0;
    for (final (i, p) in painters.indexed) {
      final color = rows[i].$1;
      if (color != null) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              left + pad,
              y + (p.height - swatch) / 2,
              swatch,
              swatch,
            ),
            const Radius.circular(2),
          ),
          Paint()..color = color,
        );
      }
      p.paint(canvas, Offset(left + pad + indent, y));
      y += p.height + rowGap;
      p.dispose();
    }
  }

  static String _value(double v) {
    if (v.isNaN) return 'undefined';
    if (v.isInfinite) return v > 0 ? '∞' : '−∞';
    final abs = v.abs();
    final s = abs != 0 && (abs >= 1e6 || abs < 1e-3)
        ? v.toStringAsExponential(2)
        : double.parse(v.toStringAsPrecision(4)).toString();
    final trimmed = s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    return trimmed.startsWith('-') ? '−${trimmed.substring(1)}' : trimmed;
  }

  @override
  bool shouldRepaint(_ProbePainter old) =>
      !identical(old.chart, chart) || old.background != background;
}
