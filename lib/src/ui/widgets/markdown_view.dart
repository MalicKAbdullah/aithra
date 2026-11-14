import 'dart:collection';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../chat/chart_spec.dart';
import '../../chat/highlight.dart';
import '../../chat/markdown.dart';
import '../../services.dart';
import '../aithra_type.dart';
import 'chart_view.dart';
import 'math_view.dart';

/// Least-recently-used memo of [compute] results, so long chats reuse the
/// work for what is on screen without holding every message ever shown.
final class _Lru<V> {
  _Lru(this.capacity);

  final int capacity;
  final LinkedHashMap<String, V> _map = LinkedHashMap();

  V get(String key, V Function() compute) {
    final hit = _map.remove(key);
    if (hit != null) return _map[key] = hit;
    if (_map.length >= capacity) _map.remove(_map.keys.first);
    return _map[key] = compute();
  }
}

/// Renders a reply's Markdown. A finished message is parsed once and its
/// blocks cached; a streaming one (with [caret]) is parsed fresh each frame
/// and never cached, since each frame's text is a one-off prefix. Within it
/// every block but the last is final text, so their inline parses still hit
/// the cache and only the growing tail is worked out anew.
///
/// When [caret] is set (the reply is still streaming) a pulsing dot follows
/// the last word. The animation is owned by the caller, so the dot keeps its
/// phase while the text around it rebuilds.
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.text, {this.caret, super.key});

  final String text;
  final Animation<double>? caret;

  static final _blocks = _Lru<List<MdBlock>>(200);

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final base = AithraType.body.copyWith(color: c.textPrimary);
    final blocks = caret == null
        ? _blocks.get(text, () => parseMarkdown(text))
        : parseMarkdown(text);
    return _BlockColumn(blocks: blocks, base: base, colors: c, caret: caret);
  }
}

class _BlockColumn extends StatelessWidget {
  const _BlockColumn({
    required this.blocks,
    required this.base,
    required this.colors,
    this.caret,
  });

  final List<MdBlock> blocks;
  final TextStyle base;
  final SuiteColors colors;
  final Animation<double>? caret;

  @override
  Widget build(BuildContext context) {
    final caret = this.caret;
    final trailingCaret =
        caret != null && (blocks.isEmpty || !_inlineBlock(blocks.last));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: _gapBefore(blocks, i)),
            child: _block(
              context,
              blocks[i],
              i == blocks.length - 1 ? caret : null,
            ),
          ),
        if (trailingCaret)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: _Caret(caret),
          ),
      ],
    );
  }

  static bool _inlineBlock(MdBlock b) =>
      b is MdParagraph || b is MdHeading || b is MdListItem || b is MdQuote;

  /// Headings get room above and sit close to what they introduce; list
  /// items stay tight together.
  static double _gapBefore(List<MdBlock> blocks, int i) {
    if (i == 0) return 0;
    final b = blocks[i];
    final prev = blocks[i - 1];
    if (b is MdHeading) return AppSpacing.md + 2;
    if (prev is MdHeading) return AppSpacing.xs + 2;
    if (b is MdListItem && prev is MdListItem) return AppSpacing.xs;
    return AppSpacing.sm + 2;
  }

  Widget _block(BuildContext context, MdBlock b, Animation<double>? caret) {
    final c = colors;
    return switch (b) {
      MdHeading(:final level, :final text) => _InlineText(
        text,
        base: switch (level) {
          1 => AithraType.h1,
          2 => AithraType.h2,
          _ => AithraType.h3,
        }.copyWith(color: c.textPrimary),
        colors: c,
        caret: caret,
      ),
      MdParagraph(:final text) => _InlineText(
        text,
        base: base,
        colors: c,
        caret: caret,
      ),
      MdListItem(:final text, :final marker, :final indent, :final checked) =>
        Padding(
          padding: EdgeInsets.only(left: indent * 14.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: checked != null ? 24 : (marker == '•' ? 16 : 22),
                child: checked != null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(
                          checked
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 17,
                          color: checked ? c.accent : c.textTertiary,
                          semanticLabel: checked ? 'Done' : 'Not done',
                        ),
                      )
                    : Text(
                        marker,
                        style: base.copyWith(
                          color: c.textTertiary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
              ),
              Expanded(
                child: _InlineText(
                  text,
                  base: checked == true
                      ? base.copyWith(color: c.textSecondary)
                      : base,
                  colors: c,
                  caret: caret,
                ),
              ),
            ],
          ),
        ),
      MdQuote(:final blocks) => Container(
        padding: const EdgeInsets.only(left: AppSpacing.smd),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: c.border, width: 3)),
        ),
        child: _BlockColumn(
          blocks: blocks,
          base: base.copyWith(color: c.textSecondary),
          colors: c,
          caret: caret,
        ),
      ),
      MdRule() => Divider(color: c.hairline),
      MdCode(:final language, :final code, :final closed)
          when ChartSpec.languages.contains(language) =>
        ChartBlock(language: language, source: code, closed: closed),
      MdCode(:final language, :final code) => CodeBlock(
        language: language,
        code: code,
      ),
      MdMath(:final tex) => _Equation(
        tex: tex,
        child: MathView.block(
          tex,
          base.copyWith(fontSize: (base.fontSize ?? 15) + 1),
        ),
      ),
      MdTable() => TableBlock(table: b, base: base, colors: c),
    };
  }
}

/// A display equation; tapping it offers its TeX.
class _Equation extends StatelessWidget {
  const _Equation({required this.tex, required this.child});

  final String tex;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => showModalBottomSheet<void>(
      context: context,
      builder: (sheet) {
        final c = SuiteColors.of(sheet);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.lg,
              AppSpacing.gutter,
              AppSpacing.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Equation',
                  style: AithraType.h2.copyWith(color: c.textPrimary),
                ),
                const SizedBox(height: AppSpacing.sm),
                SelectableText(
                  tex,
                  style: AithraType.code.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: AppSpacing.lg),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.content_copy_rounded, size: 18),
                    label: const Text('Copy TeX'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: tex));
                      Navigator.pop(sheet);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('TeX copied')),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
    child: child,
  );
}

/// What a tap on a link offers: the address, opening it and copying it.
Future<void> showLinkSheet(BuildContext context, String url) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) {
        final c = SuiteColors.of(sheet);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.lg,
              AppSpacing.gutter,
              AppSpacing.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Link',
                  style: AithraType.h2.copyWith(color: c.textPrimary),
                ),
                const SizedBox(height: AppSpacing.sm),
                SelectableText(
                  url,
                  style: AithraType.bodySmall.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Opening it leaves Aithra and goes online.',
                  style: AithraType.caption.copyWith(color: c.textTertiary),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.content_copy_rounded, size: 18),
                      label: const Text('Copy'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: url));
                        Navigator.pop(sheet);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Link copied')),
                        );
                      },
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton.icon(
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('Open'),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final native = context.services.native;
                        Navigator.pop(sheet);
                        if (!await native.openUrl(url)) {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('No app on this phone opens it'),
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

/// A Markdown table: scrolls sideways when wider than the reply, with a
/// copy button that puts it on the clipboard as tab-separated values.
class TableBlock extends StatelessWidget {
  const TableBlock({
    required this.table,
    required this.base,
    required this.colors,
    super.key,
  });

  final MdTable table;
  final TextStyle base;
  final SuiteColors colors;

  static const _cellPad = EdgeInsets.symmetric(
    horizontal: AppSpacing.smd,
    vertical: AppSpacing.sm,
  );
  static const _maxColumn = 260.0;
  static const _minColumn = 44.0;

  /// Column widths from each column's widest cell as plain text, so the
  /// table never asks its cells for intrinsic sizes (which equations and
  /// chips cannot answer cheaply); long cells wrap at [_maxColumn].
  List<double> _widths(TextScaler scaler, TextStyle style) {
    final widths = List.filled(table.header.length, _minColumn);
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    );
    for (final (r, row) in [table.header, ...table.rows].indexed) {
      for (final (i, cell) in row.indexed) {
        painter
          ..text = TextSpan(
            text: plainPreview(cell),
            style: r == 0 ? style.copyWith(fontWeight: FontWeight.w600) : style,
          )
          ..layout();
        final w = painter.width + _cellPad.horizontal + 2;
        if (w > widths[i]) widths[i] = w.clamp(_minColumn, _maxColumn);
      }
    }
    painter.dispose();
    return widths;
  }

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final style = base.copyWith(fontSize: (base.fontSize ?? 15) - 1);
    final widths = _widths(MediaQuery.textScalerOf(context), style);
    TextAlign align(int i) => switch (table.align[i]) {
      MdAlign.start => TextAlign.start,
      MdAlign.center => TextAlign.center,
      MdAlign.end => TextAlign.end,
    };
    Widget cell(String text, int i, {required bool head}) => Padding(
      padding: _cellPad,
      child: _InlineText(
        text,
        base: head ? style.copyWith(fontWeight: FontWeight.w600) : style,
        colors: c,
        textAlign: align(i),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RepaintBoundary(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: c.hairline),
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                child: Table(
                  columnWidths: {
                    for (final (i, w) in widths.indexed) i: FixedColumnWidth(w),
                  },
                  border: TableBorder(
                    horizontalInside: BorderSide(color: c.hairline),
                    verticalInside: BorderSide(color: c.hairline),
                  ),
                  children: [
                    TableRow(
                      decoration: BoxDecoration(color: c.surfaceAlt),
                      children: [
                        for (final (i, h) in table.header.indexed)
                          cell(h, i, head: true),
                      ],
                    ),
                    for (final row in table.rows)
                      TableRow(
                        children: [
                          for (final (i, v) in row.indexed)
                            cell(v, i, head: false),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: c.textTertiary,
              textStyle: AithraType.caption,
            ),
            icon: const Icon(Icons.content_copy_rounded, size: 14),
            label: const Text('Copy table'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: tableTsv(table)));
              HapticFeedback.selectionClick();
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Table copied')));
            },
          ),
        ),
      ],
    );
  }
}

/// One run of inline Markdown. Inline code is drawn as a rounded chip
/// painted behind the glyphs by [_ChipParagraph], so it wraps with the text
/// and costs no extra widgets.
class _InlineText extends StatefulWidget {
  const _InlineText(
    this.text, {
    required this.base,
    required this.colors,
    this.caret,
    this.textAlign = TextAlign.start,
  });

  final String text;
  final TextStyle base;
  final SuiteColors colors;
  final Animation<double>? caret;
  final TextAlign textAlign;

  @override
  State<_InlineText> createState() => _InlineTextState();
}

class _InlineTextState extends State<_InlineText> {
  /// Hair spaces pad each chip so its rounded edge clears the glyphs.
  static const _pad = ' ';

  /// Inline parses of final text (finished replies, and every block of a
  /// streaming reply but the one still growing).
  static final _inlines = _Lru<List<MdSpan>>(600);

  final _math = InlineMath();

  /// Tap handlers for this paragraph's links, by address; kept across
  /// rebuilds and released with the paragraph.
  final Map<String, TapGestureRecognizer> _links = {};

  @override
  void dispose() {
    for (final r in _links.values) {
      r.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _link(String url) =>
      _links[url] ??= TapGestureRecognizer()
        ..onTap = () => showLinkSheet(context, url);

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final base = widget.base;
    final runs = widget.caret == null
        ? _inlines.get(widget.text, () => parseInline(widget.text))
        : parseInline(widget.text);
    final math = _math.spansFor([
      for (final s in runs)
        if (s.style == InlineStyle.math || s.style == InlineStyle.displayMath)
          (
            tex: s.text,
            display: s.style == InlineStyle.displayMath,
            style: base,
          ),
    ]);
    var equation = 0;
    final chips = <TextRange>[];
    var offset = 0;
    final children = <InlineSpan>[];
    final linkStyle = TextStyle(
      color: c.accent,
      decoration: TextDecoration.underline,
      decorationColor: c.accent.withValues(alpha: 0.5),
    );
    const strike = TextStyle(decoration: TextDecoration.lineThrough);
    for (final s in runs) {
      if (s.style == InlineStyle.math || s.style == InlineStyle.displayMath) {
        final spans = math[equation++];
        children.addAll(spans);
        // Widget spans stand for one placeholder character each, and the
        // spans between them are single spaces.
        offset += spans.length;
        continue;
      }
      final url = s.url;
      final recognizer = url == null ? null : _link(url);
      if (s.style == InlineStyle.code) {
        final t = '$_pad${s.text}$_pad';
        chips.add(TextRange(start: offset, end: offset + t.length));
        children.add(
          TextSpan(
            text: t,
            recognizer: recognizer,
            style: AithraType.code.copyWith(
              color: url == null ? c.textPrimary : c.accent,
              fontSize: (base.fontSize ?? 15) - 2,
            ),
          ),
        );
        offset += t.length;
        continue;
      }
      var style = switch (s.style) {
        InlineStyle.plain ||
        InlineStyle.code ||
        InlineStyle.math ||
        InlineStyle.displayMath => null,
        InlineStyle.bold => const TextStyle(fontWeight: FontWeight.w600),
        InlineStyle.italic => const TextStyle(fontStyle: FontStyle.italic),
        InlineStyle.boldItalic => const TextStyle(
          fontWeight: FontWeight.w600,
          fontStyle: FontStyle.italic,
        ),
        InlineStyle.link => linkStyle,
      };
      if (s.strike) style = style?.merge(strike) ?? strike;
      children.add(
        TextSpan(text: s.text, style: style, recognizer: recognizer),
      );
      offset += s.text.length;
    }
    final caret = widget.caret;
    if (caret != null) {
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: _Caret(caret),
          ),
        ),
      );
    }
    return _ChipText(
      text: TextSpan(style: base, children: children),
      chips: chips,
      chipColor: c.surfaceAlt,
      chipBorder: c.hairline,
      textScaler: MediaQuery.textScalerOf(context),
      textAlign: widget.textAlign,
      selectionRegistrar: SelectionContainer.maybeOf(context),
      selectionColor: DefaultSelectionStyle.of(context).selectionColor,
    );
  }
}

class _ChipText extends RichText {
  _ChipText({
    required super.text,
    required this.chips,
    required this.chipColor,
    required this.chipBorder,
    required super.textScaler,
    required super.textAlign,
    required super.selectionRegistrar,
    required super.selectionColor,
  });

  final List<TextRange> chips;
  final Color chipColor;
  final Color chipBorder;

  @override
  RenderParagraph createRenderObject(BuildContext context) => _ChipParagraph(
    text,
    textDirection: Directionality.of(context),
    textScaler: textScaler,
    textAlign: textAlign,
    locale: Localizations.maybeLocaleOf(context),
    registrar: selectionRegistrar,
    selectionColor: selectionColor,
    chips: chips,
    chipColor: chipColor,
    chipBorder: chipBorder,
  );

  @override
  void updateRenderObject(BuildContext context, RenderParagraph renderObject) {
    super.updateRenderObject(context, renderObject);
    (renderObject as _ChipParagraph)
      ..chips = chips
      ..chipColor = chipColor
      ..chipBorder = chipBorder;
  }
}

class _ChipParagraph extends RenderParagraph {
  _ChipParagraph(
    super.text, {
    required super.textDirection,
    required super.textScaler,
    required super.textAlign,
    required super.locale,
    required super.registrar,
    required super.selectionColor,
    required List<TextRange> chips,
    required Color chipColor,
    required Color chipBorder,
  }) : _chips = chips,
       _chipColor = chipColor,
       _chipBorder = chipBorder;

  List<TextRange> _chips;
  set chips(List<TextRange> v) {
    if (_listEquals(v, _chips)) return;
    _chips = v;
    markNeedsLayout();
  }

  Color _chipColor;
  set chipColor(Color v) {
    if (v == _chipColor) return;
    _chipColor = v;
    markNeedsPaint();
  }

  Color _chipBorder;
  set chipBorder(Color v) {
    if (v == _chipBorder) return;
    _chipBorder = v;
    markNeedsPaint();
  }

  /// Chip rectangles for the current layout; filled on first paint (text
  /// boxes are only readable once layout has finished) and reused after.
  List<RRect>? _rects;

  static bool _listEquals(List<TextRange> a, List<TextRange> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void performLayout() {
    super.performLayout();
    _rects = null;
  }

  List<RRect> _layoutRects() => [
    for (final r in _chips)
      for (final box in getBoxesForSelection(
        TextSelection(baseOffset: r.start, extentOffset: r.end),
      ))
        RRect.fromLTRBR(
          box.left,
          box.top + 1,
          box.right,
          box.bottom - 1,
          const Radius.circular(5),
        ),
  ];

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_chips.isNotEmpty) {
      final fill = Paint()..color = _chipColor;
      final stroke = Paint()
        ..color = _chipBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      for (final r in _rects ??= _layoutRects()) {
        final shifted = r.shift(offset);
        context.canvas
          ..drawRRect(shifted, fill)
          ..drawRRect(shifted.deflate(0.5), stroke);
      }
    }
    super.paint(context, offset);
  }
}

/// The streaming indicator: a small accent dot that breathes.
class _Caret extends StatelessWidget {
  const _Caret(this.animation);

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: animation,
    child: Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: SuiteColors.of(context).accent,
        shape: BoxShape.circle,
      ),
    ),
  );
}

/// Code with a language label, copy button, light syntax colouring and
/// horizontal scrolling. Edge fades show when lines run past the card.
class CodeBlock extends StatefulWidget {
  const CodeBlock({required this.language, required this.code, super.key});

  final String language;
  final String code;

  static final Map<String, List<CodeToken>> _cache = {};

  static List<CodeToken> tokens(String language, String code) {
    final key = '$language\u0000$code';
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length > 100) _cache.remove(_cache.keys.first);
    return _cache[key] = highlight(code, language);
  }

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  /// Whether content lies past the left and right edges.
  final _overflow = ValueNotifier<(bool, bool)>((false, false));

  @override
  void dispose() {
    _overflow.dispose();
    super.dispose();
  }

  bool _onMetrics(ScrollMetrics m) {
    _overflow.value = (
      m.pixels > m.minScrollExtent + 0.5,
      m.pixels < m.maxScrollExtent - 0.5,
    );
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark
        ? Color.alphaBlend(const Color(0x0AFFFFFF), c.surface)
        : c.surfaceAlt;
    final palette = _palette(c, dark);
    final code = AithraType.code.copyWith(color: c.textPrimary);
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
          Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.only(left: AppSpacing.smd),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.hairline)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.language.isEmpty ? 'code' : widget.language,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AithraType.caption.copyWith(color: c.textTertiary),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Copy code',
                  iconSize: 16,
                  icon: const Icon(Icons.content_copy_rounded),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: widget.code));
                    HapticFeedback.selectionClick();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied')),
                    );
                  },
                ),
              ],
            ),
          ),
          Stack(
            children: [
              NotificationListener<ScrollMetricsNotification>(
                onNotification: (n) => _onMetrics(n.metrics),
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) =>
                      n.depth == 0 ? _onMetrics(n.metrics) : false,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.smd,
                      AppSpacing.smd,
                      AppSpacing.smd,
                      AppSpacing.smd,
                    ),
                    child: Text.rich(
                      TextSpan(
                        style: code,
                        children: [
                          for (final t in CodeBlock.tokens(
                            widget.language,
                            widget.code,
                          ))
                            TextSpan(text: t.text, style: palette[t.kind]),
                        ],
                      ),
                      softWrap: false,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: ValueListenableBuilder<(bool, bool)>(
                    valueListenable: _overflow,
                    builder: (context, o, _) => Row(
                      children: [
                        _Fade(color: bg, visible: o.$1, toRight: false),
                        const Spacer(),
                        _Fade(color: bg, visible: o.$2, toRight: true),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Map<TokenKind, TextStyle?> _palette(SuiteColors c, bool dark) => {
    TokenKind.plain: null,
    TokenKind.keyword: TextStyle(
      color: dark ? const Color(0xFFC4A7FF) : const Color(0xFF7A3FD1),
    ),
    TokenKind.string: TextStyle(
      color: dark ? const Color(0xFF9FD89A) : const Color(0xFF2F7A34),
    ),
    TokenKind.number: TextStyle(color: c.accent),
    TokenKind.comment: TextStyle(
      color: c.textTertiary,
      fontStyle: FontStyle.italic,
    ),
  };
}

class _Fade extends StatelessWidget {
  const _Fade({
    required this.color,
    required this.visible,
    required this.toRight,
  });

  final Color color;
  final bool visible;
  final bool toRight;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: visible ? 1 : 0,
    duration: AppMotion.fast,
    child: Container(
      width: 28,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: toRight ? Alignment.centerLeft : Alignment.centerRight,
          end: toRight ? Alignment.centerRight : Alignment.centerLeft,
          colors: [color.withValues(alpha: 0), color],
        ),
      ),
    ),
  );
}
