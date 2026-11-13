import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// LaTeX in replies, typeset by flutter_math_fork. Widgets are cached per
/// equation and style: a streaming reply rebuilds its text every frame, and
/// handing Flutter the identical widget lets it skip re-parsing and
/// re-laying out every equation already on screen.
abstract final class MathView {
  static final Map<String, Object> _cache = {};

  static T _cached<T extends Object>(String key, T Function() build) {
    final hit = _cache[key];
    if (hit is T) return hit;
    if (_cache.length > 300) _cache.remove(_cache.keys.first);
    return _cache[key] = build();
  }

  static String _key(String kind, String tex, TextStyle style) =>
      '$kind|${style.fontSize}|${style.color?.toARGB32()}|$tex';

  /// Malformed LaTeX shows its source, so only that equation is affected.
  static Widget _source(String source, TextStyle style) =>
      Text(source, style: style);

  /// Inline math as spans that the paragraph can wrap between, at the
  /// break points TeX itself allows (after relations and binary operators).
  static List<InlineSpan> inline(
    String tex,
    TextStyle style, {
    required bool display,
  }) {
    final parts = _cached(_key(display ? 'd' : 'i', tex, style), () {
      final source = display ? '\$\$$tex\$\$' : '\$$tex\$';
      final math = Math.tex(
        tex,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        textStyle: style,
        onErrorFallback: (_) => _source(source, style),
      );
      return [
        for (final part in math.texBreak().parts)
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: part,
          ),
      ];
    });
    return parts;
  }

  /// A display equation: centred when it fits, scrolling sideways when it
  /// is wider than the reply.
  static Widget block(String tex, TextStyle style) =>
      _cached(_key('b', tex, style), () => _MathBlock(tex: tex, style: style));
}

class _MathBlock extends StatelessWidget {
  const _MathBlock({required this.tex, required this.style});

  final String tex;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final math = Math.tex(
      tex,
      mathStyle: MathStyle.display,
      textStyle: style,
      onErrorFallback: (_) => MathView._source('\$\$$tex\$\$', style),
    );
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: box.maxWidth),
          child: Center(child: math),
        ),
      ),
    );
  }
}
