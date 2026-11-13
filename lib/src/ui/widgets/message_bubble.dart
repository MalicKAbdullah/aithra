import 'dart:typed_data';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../../chat/chat_session.dart';
import '../../services.dart';
import '../aithra_type.dart';
import 'markdown_view.dart';

/// Decrypted image thumbnails, kept for the session so scrolling back does
/// not hit the store again.
class ThumbCache {
  static final Map<String, Uint8List> _thumbs = {};

  static Future<Uint8List?> get(BuildContext context, String id) async {
    final hit = _thumbs[id];
    if (hit != null) return hit;
    final bytes = await context.services.native.dbImage(id, thumb: true);
    if (bytes != null) {
      if (_thumbs.length > 300) _thumbs.remove(_thumbs.keys.first);
      _thumbs[id] = bytes;
    }
    return bytes;
  }

  static Uint8List? peek(String id) => _thumbs[id];
}

class Thumb extends StatelessWidget {
  const Thumb(this.id, {this.size = 120, super.key});

  final String id;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget frame(Widget child) => ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: SizedBox(width: size, height: size, child: child),
    );
    final cached = ThumbCache.peek(id);
    if (cached != null) {
      return frame(
        Image.memory(
          cached,
          fit: BoxFit.cover,
          cacheWidth: (size * dpr).round(),
          gaplessPlayback: true,
        ),
      );
    }
    return FutureBuilder<Uint8List?>(
      future: ThumbCache.get(context, id),
      builder: (context, snap) => frame(
        snap.data == null
            ? ColoredBox(color: c.surfaceAlt)
            : Image.memory(
                snap.data!,
                fit: BoxFit.cover,
                cacheWidth: (size * dpr).round(),
              ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.message,
    required this.onLongPress,
    super.key,
  });

  final ChatMessage message;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final user = message.role == Role.user;
    final content = Column(
      crossAxisAlignment: user
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (message.imageIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              alignment: WrapAlignment.end,
              children: [for (final id in message.imageIds) Thumb(id)],
            ),
          ),
        if (message.content.isNotEmpty)
          user
              ? Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.smd + 2,
                    vertical: AppSpacing.sm + 1,
                  ),
                  decoration: BoxDecoration(
                    color: c.accentContainer,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                  ),
                  child: Text(
                    message.content,
                    style: AithraType.body.copyWith(color: c.textPrimary),
                  ),
                )
              : MarkdownView(message.content),
      ],
    );
    return GestureDetector(
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          user ? 56 : AppSpacing.gutter,
          AppSpacing.sm - 2,
          AppSpacing.gutter,
          AppSpacing.sm - 2,
        ),
        child: Align(
          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
          child: content,
        ),
      ),
    );
  }
}

/// The reply being generated. Only this widget rebuilds while tokens stream;
/// it owns the caret animation so the caret keeps its rhythm across those
/// rebuilds without touching finished messages.
class StreamingBubble extends StatefulWidget {
  const StreamingBubble({required this.session, super.key});

  final ChatSession session;

  @override
  State<StreamingBubble> createState() => _StreamingBubbleState();
}

class _StreamingBubbleState extends State<StreamingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _caret = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    lowerBound: 0.25,
  );
  late final Animation<double> _breath = CurvedAnimation(
    parent: _caret,
    curve: Curves.easeInOut,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _caret.value = 1;
    } else if (!_caret.isAnimating) {
      _caret.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _caret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.gutter,
          vertical: AppSpacing.sm - 2,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: widget.session.phase == ReplyPhase.queued
              ? const _Queued()
              : ValueListenableBuilder<String>(
                  valueListenable: widget.session.streaming,
                  builder: (context, text, _) => text.isEmpty
                      ? const TypingDots()
                      : MarkdownView(text, caret: _breath),
                ),
        ),
      ),
    );
  }
}

/// A reply waiting for another chat's reply to finish with the engine.
class _Queued extends StatelessWidget {
  const _Queued();

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return SizedBox(
      height: 24,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_rounded, size: 16, color: c.textTertiary),
          const SizedBox(width: 6),
          Text(
            'Queued · starts when the other reply finishes',
            style: AithraType.bodySmall.copyWith(color: c.textTertiary),
          ),
        ],
      ),
    );
  }
}

class TypingDots extends StatefulWidget {
  const TypingDots({super.key});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = SuiteColors.of(context).textTertiary;
    return SizedBox(
      height: 24,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Transform.translate(
                  offset: Offset(0, -3 * _bounce((_c.value - i * 0.15) % 1)),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static double _bounce(double t) => t < 0.5 ? (t * 2) : (2 - t * 2);
}
