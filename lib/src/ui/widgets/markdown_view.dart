import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../chat/highlight.dart';
import '../../chat/markdown.dart';
import '../aithra_type.dart';
import 'math_view.dart';

/// Renders a reply's Markdown. Parsed blocks are cached per text, so a
/// finished message is parsed once; a streaming one re-parses only when its
/// text changes (once per frame at most).
///
/// When [caret] is set (the reply is still streaming) a pulsing dot follows
/// the last word. The animation is owned by the caller, so the dot keeps its
/// phase while the text around it rebuilds.
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.text, {this.caret, super.key});

  final String text;
  final Animation<double>? caret;

  static final Map<String, List<MdBlock>> _cache = {};

  static List<MdBlock> _parse(String text) {
    final hit = _cache[text];
    if (hit != null) return hit;
    if (_cache.length > 200) _cache.remove(_cache.keys.first);
    return _cache[text] = parseMarkdown(text);
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final base = AithraType.body.copyWith(color: c.textPrimary);
    final blocks = _parse(text);
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
              blocks[i],
              base,
              c,
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

  Widget _block(
    MdBlock b,
    TextStyle base,
    SuiteColors c,
    Animation<double>? caret,
  ) => switch (b) {
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
    MdListItem(:final text, :final marker, :final indent) => Padding(
      padding: EdgeInsets.only(left: indent * 14.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: marker == '•' ? 16 : 22,
            child: Text(
              marker,
              style: base.copyWith(
                color: c.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: _InlineText(text, base: base, colors: c, caret: caret),
          ),
        ],
      ),
    ),
    MdQuote(:final text) => Container(
      padding: const EdgeInsets.only(left: AppSpacing.smd),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.border, width: 3)),
      ),
      child: _InlineText(
        text,
        base: base.copyWith(color: c.textSecondary),
        colors: c,
        caret: caret,
      ),
    ),
    MdRule() => Divider(color: c.hairline),
    MdCode(:final language, :final code) => CodeBlock(
      language: language,
      code: code,
    ),
    MdMath(:final tex) => MathView.block(
      tex,
      base.copyWith(fontSize: (base.fontSize ?? 15) + 1),
    ),
  };
}

/// One run of inline Markdown. Inline code is drawn as a rounded chip
/// painted behind the glyphs by [_ChipParagraph], so it wraps with the text
/// and costs no extra widgets.
class _InlineText extends StatelessWidget {
  const _InlineText(
    this.text, {
    required this.base,
    required this.colors,
    this.caret,
  });

  final String text;
  final TextStyle base;
  final SuiteColors colors;
  final Animation<double>? caret;

  /// Hair spaces pad each chip so its rounded edge clears the glyphs.
  static const _pad = ' ';

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final chips = <TextRange>[];
    var offset = 0;
    final children = <InlineSpan>[];
    for (final s in parseInline(text)) {
      if (s.style == InlineStyle.math || s.style == InlineStyle.displayMath) {
        final spans = MathView.inline(
          s.text,
          base,
          display: s.style == InlineStyle.displayMath,
        );
        children.addAll(spans);
        // Each widget span stands for one placeholder character.
        offset += spans.length;
        continue;
      }
      if (s.style == InlineStyle.code) {
        final t = '$_pad${s.text}$_pad';
        chips.add(TextRange(start: offset, end: offset + t.length));
        children.add(
          TextSpan(
            text: t,
            style: AithraType.code.copyWith(
              color: c.textPrimary,
              fontSize: (base.fontSize ?? 15) - 2,
            ),
          ),
        );
        offset += t.length;
        continue;
      }
      children.add(
        TextSpan(
          text: s.text,
          style: switch (s.style) {
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
            InlineStyle.link => TextStyle(
              color: c.accent,
              decoration: TextDecoration.underline,
              decorationColor: c.accent.withValues(alpha: 0.5),
            ),
          },
        ),
      );
      offset += s.text.length;
    }
    final caret = this.caret;
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
  });

  final List<TextRange> chips;
  final Color chipColor;
  final Color chipBorder;

  @override
  RenderParagraph createRenderObject(BuildContext context) => _ChipParagraph(
    text,
    textDirection: Directionality.of(context),
    textScaler: textScaler,
    locale: Localizations.maybeLocaleOf(context),
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
    required super.locale,
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
            height: 36,
            padding: const EdgeInsets.only(left: AppSpacing.smd),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.hairline)),
            ),
            child: Row(
              children: [
                Text(
                  widget.language.isEmpty ? 'code' : widget.language,
                  style: AithraType.caption.copyWith(color: c.textTertiary),
                ),
                const Spacer(),
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
