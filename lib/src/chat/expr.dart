import 'dart:math' as math;

/// A function of `x` compiled from text such as `2sin(x) + x^2/4`.
typedef Fx = double Function(double x);

/// Compiles [source] with a recursive-descent parser. Throws a
/// [FormatException] pointing at the offending character for anything it
/// cannot read.
///
/// Grammar, loosest binding first:
///   sum     := product (('+' | '-') product)*
///   product := unary (('*' | '/') unary | unary)*   (juxtaposition multiplies)
///   unary   := ('-' | '+') unary | power
///   power   := atom (('^' | '**') unary)?           (right-associative)
///   atom    := number | 'x' | constant | name '(' sum (',' sum)* ')'
///            | '(' sum ')'
Fx compileExpr(String source) => _ExprParser(source).parse();

class _ExprParser {
  _ExprParser(this.src);

  final String src;
  int i = 0;

  Fx parse() {
    final f = _sum();
    _skip();
    if (i < src.length) _fail('Unexpected "${src[i]}"');
    return f;
  }

  Never _fail(String message) => throw FormatException(message, src, i);

  void _skip() {
    while (i < src.length && (src[i] == ' ' || src[i] == '\t')) {
      i++;
    }
  }

  bool _eat(String token) {
    _skip();
    if (src.startsWith(token, i)) {
      i += token.length;
      return true;
    }
    return false;
  }

  Fx _sum() {
    var f = _product();
    while (true) {
      if (_eat('+')) {
        final a = f, b = _product();
        f = (x) => a(x) + b(x);
      } else if (_eat('-')) {
        final a = f, b = _product();
        f = (x) => a(x) - b(x);
      } else {
        return f;
      }
    }
  }

  Fx _product() {
    var f = _unary();
    while (true) {
      _skip();
      if (src.startsWith('**', i)) return f;
      if (_eat('*') || _eat('×') || _eat('·')) {
        final a = f, b = _unary();
        f = (x) => a(x) * b(x);
      } else if (_eat('/') || _eat('÷')) {
        final a = f, b = _unary();
        f = (x) => a(x) / b(x);
      } else if (i < src.length && _startsAtom(src[i])) {
        final a = f, b = _power();
        f = (x) => a(x) * b(x);
      } else {
        return f;
      }
    }
  }

  static bool _startsAtom(String c) =>
      c == '(' || c == 'π' || RegExp(r'[A-Za-z0-9.]').hasMatch(c);

  Fx _unary() {
    if (_eat('-') || _eat('−')) {
      final a = _unary();
      return (x) => -a(x);
    }
    if (_eat('+')) return _unary();
    return _power();
  }

  Fx _power() {
    final base = _atom();
    if (_eat('^') || _eat('**')) {
      final exp = _unary();
      return (x) => math.pow(base(x), exp(x)).toDouble();
    }
    return base;
  }

  Fx _atom() {
    _skip();
    if (i >= src.length) _fail('Expression ends too early');
    final c = src[i];
    if (c == '(') {
      i++;
      final f = _sum();
      if (!_eat(')')) _fail('Missing ")"');
      return f;
    }
    if (c == 'π') {
      i++;
      return (_) => math.pi;
    }
    final number = RegExp(
      r'(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?',
    ).matchAsPrefix(src, i);
    if (number != null) {
      i = number.end;
      final v = double.parse(number[0]!);
      return (_) => v;
    }
    final name = RegExp('[A-Za-z_][A-Za-z_0-9]*').matchAsPrefix(src, i);
    if (name == null) _fail('Unexpected "$c"');
    final word = name[0]!;
    final at = i;
    i = name.end;
    if (word == 'x') return (x) => x;
    final constant = _constants[word];
    if (constant != null) return (_) => constant;
    final fn = _functions[word];
    if (fn == null) {
      i = at;
      _fail('Unknown name "$word"');
    }
    if (!_eat('(')) _fail('"$word" needs "("');
    final args = <Fx>[_sum()];
    while (_eat(',')) {
      args.add(_sum());
    }
    if (!_eat(')')) _fail('Missing ")"');
    if (args.length != fn.arity) {
      _fail('"$word" takes ${fn.arity} argument${fn.arity == 1 ? '' : 's'}');
    }
    return fn.bind(args);
  }
}

const _constants = {'pi': math.pi, 'e': math.e, 'tau': 2 * math.pi};

class _Fn {
  const _Fn.one(double Function(double) this.f1) : f2 = null, arity = 1;
  const _Fn.two(double Function(double, double) this.f2) : f1 = null, arity = 2;

  final double Function(double)? f1;
  final double Function(double, double)? f2;
  final int arity;

  Fx bind(List<Fx> args) {
    if (f1 case final f?) {
      final a = args[0];
      return (x) => f(a(x));
    }
    final f = f2!;
    final a = args[0], b = args[1];
    return (x) => f(a(x), b(x));
  }
}

double _sign(double v) => v.isNaN ? v : v.sign;
double _cbrt(double v) =>
    v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();
double _sinh(double v) => (math.exp(v) - math.exp(-v)) / 2;
double _cosh(double v) => (math.exp(v) + math.exp(-v)) / 2;
double _tanh(double v) {
  if (v > 20) return 1;
  if (v < -20) return -1;
  final a = math.exp(2 * v);
  return (a - 1) / (a + 1);
}

final _functions = <String, _Fn>{
  'sin': const _Fn.one(math.sin),
  'cos': const _Fn.one(math.cos),
  'tan': const _Fn.one(math.tan),
  'asin': const _Fn.one(math.asin),
  'acos': const _Fn.one(math.acos),
  'atan': const _Fn.one(math.atan),
  'arcsin': const _Fn.one(math.asin),
  'arccos': const _Fn.one(math.acos),
  'arctan': const _Fn.one(math.atan),
  'sinh': const _Fn.one(_sinh),
  'cosh': const _Fn.one(_cosh),
  'tanh': const _Fn.one(_tanh),
  'sec': _Fn.one((v) => 1 / math.cos(v)),
  'csc': _Fn.one((v) => 1 / math.sin(v)),
  'cot': _Fn.one((v) => 1 / math.tan(v)),
  'exp': const _Fn.one(math.exp),
  'ln': const _Fn.one(math.log),
  'log': _Fn.one((v) => math.log(v) / math.ln10),
  'log10': _Fn.one((v) => math.log(v) / math.ln10),
  'log2': _Fn.one((v) => math.log(v) / math.ln2),
  'sqrt': const _Fn.one(math.sqrt),
  'cbrt': const _Fn.one(_cbrt),
  'abs': _Fn.one((v) => v.abs()),
  'floor': _Fn.one((v) => v.floorToDouble()),
  'ceil': _Fn.one((v) => v.ceilToDouble()),
  'round': _Fn.one((v) => v.roundToDouble()),
  'sign': const _Fn.one(_sign),
  'min': const _Fn.two(math.min),
  'max': const _Fn.two(math.max),
  'pow': _Fn.two((a, b) => math.pow(a, b).toDouble()),
  'atan2': const _Fn.two(math.atan2),
  'mod': _Fn.two((a, b) => a % b),
};
