import 'package:flutter/material.dart';
import 'package:flutter_math_fork/ast.dart';
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

  /// Inline math as spans that the paragraph can wrap between, after the
  /// relations (=, <, …) where TeX allows a break.
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
      final pieces = _relationPieces(math);
      // A piece ends after a relation, whose trailing space TeX drops at a
      // break; the text space between pieces puts it back and is where the
      // line may wrap.
      return [
        for (final (i, piece) in pieces.indexed) ...[
          if (i > 0) const TextSpan(text: ' '),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: piece,
          ),
        ],
      ];
    });
    return parts;
  }

  static const _binOpPenalty = 700;

  /// [math] cut after each relation (=, <, …), the points where TeX
  /// allows a break that keeps spacing intact. TeX also allows breaks after
  /// binary operators, but a piece ending in one loses the operator's
  /// spacing on both sides, so those pieces are joined back up. Malformed
  /// TeX stays one piece, which shows its fallback.
  static List<Math> _relationPieces(Math math) {
    if (math.ast == null) return [math];
    final broken = math.texBreak(binOpPenalty: _binOpPenalty);
    final pieces = <Math>[];
    var children = <GreenNode>[];
    for (final (i, part) in broken.parts.indexed) {
      children.addAll(part.ast!.greenRoot.children);
      if (broken.penalties[i] == _binOpPenalty) continue;
      pieces.add(
        Math(
          ast: SyntaxTree(greenRoot: EquationRowNode(children: children)),
          mathStyle: math.mathStyle,
          textStyle: math.textStyle,
          onErrorFallback: math.onErrorFallback,
        ),
      );
      children = [];
    }
    return pieces;
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
