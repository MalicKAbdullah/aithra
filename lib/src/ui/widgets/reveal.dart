import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

/// Scrolls a lazily built chat list to a message and highlights it. The
/// list builds only what is near the screen, so the message may not exist
/// as a widget yet: [RevealAnchor]s report which messages are built, and
/// [reveal] scrolls toward the target a screen at a time until its anchor
/// appears, then centres it.
class RevealController extends ChangeNotifier {
  final Map<int, BuildContext> _built = {};

  /// The message highlighted after the last [reveal].
  int? highlighted;

  /// Scrolls [scroll] (a reversed list, newest message at offset 0) until
  /// the message at [seq] is centred. Newer messages have higher seqs.
  Future<void> reveal(int seq, ScrollController scroll) async {
    highlighted = seq;
    notifyListeners();
    for (var step = 0; step < 200 && scroll.hasClients; step++) {
      final target = _built[seq];
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          alignment: 0.5,
          duration: AppMotion.base,
          curve: AppMotion.emphasized,
        );
        return;
      }
      if (_built.isEmpty) return;
      final position = scroll.position;
      // Older messages sit further along a reversed list.
      final older = seq < _built.keys.reduce((a, b) => a < b ? a : b);
      final next =
          (position.pixels +
                  (older ? 1 : -1) * position.viewportDimension * 0.8)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (next == position.pixels) return;
      position.jumpTo(next);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void clear() {
    if (highlighted == null) return;
    highlighted = null;
    notifyListeners();
  }
}

/// Marks the message at [seq] in the list for [RevealController] and tints
/// it while it is the highlighted one.
class RevealAnchor extends StatefulWidget {
  const RevealAnchor({
    required this.controller,
    required this.seq,
    required this.child,
    super.key,
  });

  final RevealController controller;
  final int seq;
  final Widget child;

  @override
  State<RevealAnchor> createState() => _RevealAnchorState();
}

class _RevealAnchorState extends State<RevealAnchor> {
  @override
  void initState() {
    super.initState();
    widget.controller._built[widget.seq] = context;
  }

  @override
  void didUpdateWidget(RevealAnchor old) {
    super.didUpdateWidget(old);
    if (old.seq != widget.seq || old.controller != widget.controller) {
      _forget(old);
      widget.controller._built[widget.seq] = context;
    }
  }

  void _forget(RevealAnchor w) {
    if (identical(w.controller._built[w.seq], context)) {
      w.controller._built.remove(w.seq);
    }
  }

  @override
  void dispose() {
    _forget(widget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tint = SuiteColors.of(context).accent.withValues(alpha: 0.12);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, child) => AnimatedContainer(
        duration: AppMotion.slow,
        curve: AppMotion.standard,
        color: widget.controller.highlighted == widget.seq
            ? tint
            : tint.withValues(alpha: 0),
        child: child,
      ),
      child: widget.child,
    );
  }
}
