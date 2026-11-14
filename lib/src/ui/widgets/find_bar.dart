import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../../chat/chat_session.dart';
import '../aithra_type.dart';

/// Finds words in the open chat. Matches come newest first; the arrows step
/// to older and newer ones, and each step shows its message through
/// [onShow].
class FindBar extends StatefulWidget {
  const FindBar({required this.session, required this.onShow, super.key});

  final ChatSession session;
  final void Function(int seq) onShow;

  @override
  State<FindBar> createState() => _FindBarState();
}

class _FindBarState extends State<FindBar> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<int> _matches = const [];
  int _at = 0;
  bool _searched = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      final found = await widget.session.find(q);
      if (!mounted || q != _query.text) return;
      setState(() {
        _matches = found;
        _at = 0;
        _searched = q.trim().isNotEmpty;
      });
      if (found.isNotEmpty) widget.onShow(found.first);
    });
  }

  void _step(int by) {
    final next = _at + by;
    if (next < 0 || next >= _matches.length) return;
    setState(() => _at = next);
    widget.onShow(_matches[next]);
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final count = _matches.isEmpty
        ? (_searched ? 'No matches' : '')
        : '${_at + 1} of ${_matches.length}';
    return Material(
      color: c.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.xs,
          AppSpacing.xs,
          AppSpacing.xs,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _changed,
                onSubmitted: (_) => _step(1),
                decoration: const InputDecoration(
                  hintText: 'Find in chat',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            Text(
              count,
              style: AithraType.caption.copyWith(
                color: c.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            IconButton(
              tooltip: 'Older match',
              icon: const Icon(Icons.keyboard_arrow_up_rounded),
              onPressed: _at + 1 < _matches.length ? () => _step(1) : null,
            ),
            IconButton(
              tooltip: 'Newer match',
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              onPressed: _at > 0 ? () => _step(-1) : null,
            ),
            IconButton(
              tooltip: 'Close find',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => widget.session.finding.value = false,
            ),
          ],
        ),
      ),
    );
  }
}
