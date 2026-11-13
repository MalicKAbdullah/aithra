import 'dart:async';

/// Gives the engine to one chat reply at a time. The engine holds one model
/// and runs one generation, so a reply asked for in one chat while another
/// chat's reply runs waits here, first come first served, and can be
/// withdrawn (Stop) while it waits.
class ReplyQueue {
  Object? _running;
  final List<(Object, Completer<bool>)> _waiting = [];

  /// Whether a reply holds the engine.
  bool get busy => _running != null;

  /// Completes with true once [owner] holds the engine, or false when it
  /// was withdrawn while waiting. Every true must be matched by [release].
  Future<bool> acquire(Object owner) {
    assert(!identical(_running, owner) && !isWaiting(owner));
    if (_running == null) {
      _running = owner;
      return Future.value(true);
    }
    final turn = Completer<bool>();
    _waiting.add((owner, turn));
    return turn.future;
  }

  bool isWaiting(Object owner) => _waiting.any((w) => identical(w.$1, owner));

  /// Hands the engine to the next waiting reply.
  void release(Object owner) {
    assert(identical(_running, owner));
    _running = null;
    if (_waiting.isEmpty) return;
    final (next, turn) = _waiting.removeAt(0);
    _running = next;
    turn.complete(true);
  }

  /// Takes [owner] out of the line; its [acquire] completes with false.
  void withdraw(Object owner) {
    final i = _waiting.indexWhere((w) => identical(w.$1, owner));
    if (i < 0) return;
    _waiting.removeAt(i).$2.complete(false);
  }
}
