import 'package:flutter/material.dart';
import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// LaTeX in replies, typeset by flutter_math_fork.
///
/// A parsed equation may be on screen in one place only. flutter_math_fork
/// keeps each row's build result, including the GlobalKey of its `Line`
/// widget, on the parsed tree itself, so two placements of one tree share
/// that key and the later one takes the earlier one's render object. Inline
/// equations are therefore owned by the paragraph showing them
/// ([InlineMath]), and block equations parse inside their own build.
abstract final class MathView {
  static final Map<String, Widget> _blocks = {};

  /// Malformed LaTeX shows its source, so only that equation is affected.
  static Widget _source(String source, TextStyle style) =>
      Text(source, style: style);

  /// A display equation: centred when it fits, scrolling sideways when it
  /// is wider than the reply. The widget holds no parsed tree, so one
  /// instance can be shared by every reply showing the same equation.
  static Widget block(String tex, TextStyle style) {
    final key = '${style.fontSize}|${style.color?.toARGB32()}|$tex';
    final hit = _blocks[key];
    if (hit != null) return hit;
    if (_blocks.length > 300) _blocks.remove(_blocks.keys.first);
    return _blocks[key] = _MathBlock(tex: tex, style: style);
  }
}

/// One inline equation of a paragraph.
typedef InlineEquation = ({String tex, bool display, TextStyle style});

/// The inline equations of one paragraph, typeset once and kept across its
/// rebuilds: a streaming reply rebuilds its text every frame, and handing
/// Flutter the identical widgets lets it skip re-parsing and re-laying out
/// every equation already on screen. Equations are matched by position,
/// since streaming only appends.
final class InlineMath {
  List<(InlineEquation, List<InlineSpan>)> _built = const [];

  /// Spans for each of [equations], in order, that the paragraph can wrap
  /// between, after the relations (=, <, …) where TeX allows a break.
  List<List<InlineSpan>> spansFor(List<InlineEquation> equations) {
    _built = [
      for (final (i, e) in equations.indexed)
        i < _built.length && _built[i].$1 == e ? _built[i] : (e, _typeset(e)),
    ];
    return [for (final (_, spans) in _built) spans];
  }

  static List<InlineSpan> _typeset(InlineEquation e) {
    final source = e.display ? '\$\$${e.tex}\$\$' : '\$${e.tex}\$';
    final math = Math.tex(
      e.tex,
      mathStyle: e.display ? MathStyle.display : MathStyle.text,
      textStyle: e.style,
      onErrorFallback: (_) => MathView._source(source, e.style),
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
