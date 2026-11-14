import 'dart:typed_data';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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

/// An image in a message: a square thumbnail that opens full screen.
class Thumb extends StatefulWidget {
  const Thumb(this.id, {this.size = 120, super.key});

  final String id;
  final double size;

  @override
  State<Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<Thumb> {
  /// Started once per image, not per build, so rebuilds while it decrypts
  /// do not ask the store again.
  Future<Uint8List?>? _load;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(Thumb old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _start();
  }

  void _start() {
    _load = ThumbCache.peek(widget.id) == null
        ? ThumbCache.get(context, widget.id)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final size = widget.size;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget frame(Uint8List? bytes) => Semantics(
      button: true,
      label: 'Photo, open full screen',
      child: GestureDetector(
        onTap: bytes == null
            ? null
            : () => ImageViewer.open(context, widget.id),
        child: Hero(
          tag: 'image-${widget.id}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            child: SizedBox(
              width: size,
              height: size,
              child: bytes == null
                  ? ColoredBox(color: c.surfaceAlt)
                  : Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      cacheWidth: (size * dpr).round(),
                      gaplessPlayback: true,
                    ),
            ),
          ),
        ),
      ),
    );
    final cached = ThumbCache.peek(widget.id);
    if (cached != null) return frame(cached);
    return FutureBuilder<Uint8List?>(
      future: _load,
      builder: (context, snap) => frame(snap.data),
    );
  }
}

/// A photo full screen: pinch or double-tap to zoom, tap or fling down to
/// close. The thumbnail shows at once and the full image replaces it once
/// decrypted.
class ImageViewer extends StatefulWidget {
  const ImageViewer({required this.id, super.key});

  final String id;

  static Future<void> open(BuildContext context, String id) =>
      Navigator.of(context).push(
        PageRouteBuilder<void>(
          opaque: false,
          barrierColor: Colors.black,
          transitionDuration: AppMotion.base,
          reverseTransitionDuration: AppMotion.fast,
          pageBuilder: (_, _, _) => ImageViewer(id: id),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      );

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  final _zoom = TransformationController();
  Uint8List? _full;
  Offset _doubleTapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    context.services.native.dbImage(widget.id, thumb: false).then((bytes) {
      if (mounted && bytes != null) setState(() => _full = bytes);
    });
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    final at = _doubleTapAt;
    _zoom.value = _zoom.value.getMaxScaleOnAxis() > 1
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(-at.dx * 1.5, -at.dy * 1.5, 0, 1)
            ..scaleByDouble(2.5, 2.5, 1, 1));
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _full ?? ThumbCache.peek(widget.id);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
              onDoubleTap: _toggleZoom,
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) > 600 &&
                    _zoom.value.getMaxScaleOnAxis() <= 1) {
                  Navigator.pop(context);
                }
              },
              child: InteractiveViewer(
                transformationController: _zoom,
                maxScale: 6,
                child: Center(
                  child: Hero(
                    tag: 'image-${widget.id}',
                    child: bytes == null
                        ? const SizedBox.shrink()
                        : Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            semanticLabel: 'Photo',
                          ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                tooltip: 'Close',
                color: Colors.white,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A saved message. A user message sits in a tinted bubble and reveals its
/// actions ([footer]) on tap; a reply is set as Markdown with its actions
/// below.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.message,
    this.onTap,
    this.footer = const [],
    super.key,
  });

  final ChatMessage message;
  final VoidCallback? onTap;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    if (message.role == Role.model) {
      return ReplyLayout(body: MarkdownView(message.content), footer: footer);
    }
    final c = SuiteColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        56,
        AppSpacing.sm - 2,
        AppSpacing.gutter,
        AppSpacing.sm - 2,
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
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
              GestureDetector(
                onTap: onTap,
                child: Container(
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
                ),
              ),
            ...footer,
          ],
        ),
      ),
    );
  }
}

/// The frame of a reply: its body, then what goes under it (actions,
/// notices). Streaming and saved replies share it, so a reply keeps its
/// laid-out text when it finishes.
class ReplyLayout extends StatelessWidget {
  const ReplyLayout({required this.body, this.footer = const [], super.key});

  final Widget body;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.gutter,
      AppSpacing.sm - 2,
      AppSpacing.gutter,
      AppSpacing.sm - 2,
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [body, ...footer],
      ),
    ),
  );
}

/// One reply in a chat, from waiting through streaming to saved. It stays
/// the same widget (under the same key) across those stages, so the text
/// laid out while streaming is reused as is when the reply is saved,
/// instead of being rebuilt and re-typeset.
class ModelTurn extends StatefulWidget {
  const ModelTurn({
    required this.session,
    this.message,
    this.footer = const [],
    super.key,
  });

  final ChatSession session;

  /// The saved reply; null while it is being generated.
  final ChatMessage? message;
  final List<Widget> footer;

  @override
  State<ModelTurn> createState() => _ModelTurnState();
}

class _ModelTurnState extends State<ModelTurn>
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
  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ModelTurn old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session && _listening) {
      old.session.streaming.removeListener(_onText);
      _listening = false;
    }
    _sync();
  }

  /// Rebuilds with each published chunk only while the reply streams, and
  /// breathes the caret only then.
  void _sync() {
    final streaming = widget.message == null;
    if (streaming && !_listening) {
      widget.session.streaming.addListener(_onText);
    } else if (!streaming && _listening) {
      widget.session.streaming.removeListener(_onText);
    }
    _listening = streaming;
    if (!streaming) {
      _caret.stop();
    } else if (MediaQuery.disableAnimationsOf(context)) {
      _caret.value = 1;
    } else if (!_caret.isAnimating) {
      _caret.repeat(reverse: true);
    }
  }

  void _onText() => setState(() {});

  @override
  void dispose() {
    if (_listening) widget.session.streaming.removeListener(_onText);
    _caret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final Widget body;
    if (m != null) {
      body = MarkdownView(m.content);
    } else if (widget.session.phase == ReplyPhase.queued) {
      body = const _Queued();
    } else {
      final text = widget.session.streaming.value;
      body = text.isEmpty
          ? const TypingDots()
          : MarkdownView(text, caret: _breath);
    }
    return RepaintBoundary(
      child: ReplyLayout(body: body, footer: widget.footer),
    );
  }
}

/// Keeps the reader's place while the newest item of a reversed chat list
/// grows: when the list is scrolled away from the newest end, the scroll
/// offset follows the growth during layout, so the text being read stays
/// put instead of sliding up with every new line. Every item carries one
/// so moving away from the newest end changes only [enabled], never the
/// item's subtree.
class KeepReadingPlace extends SingleChildRenderObjectWidget {
  const KeepReadingPlace({required this.enabled, super.key, super.child});

  /// Only the newest item: growth further up the list sits above the
  /// reader, where it moves nothing on screen.
  final bool enabled;

  @override
  RenderKeepReadingPlace createRenderObject(BuildContext context) =>
      RenderKeepReadingPlace()
        ..position = enabled ? Scrollable.maybeOf(context)?.position : null;

  @override
  void updateRenderObject(
    BuildContext context,
    RenderKeepReadingPlace renderObject,
  ) => renderObject.position = enabled
      ? Scrollable.maybeOf(context)?.position
      : null;
}

class RenderKeepReadingPlace extends RenderProxyBox {
  ScrollPosition? position;
  double? _height;

  @override
  void performLayout() {
    super.performLayout();
    final before = _height;
    _height = size.height;
    final p = position;
    if (before == null || p == null || !p.hasPixels) return;
    final delta = size.height - before;
    // At the newest end (offset 0) the list follows the reply instead.
    // ScrollPosition.correctBy during layout makes the viewport lay out
    // again at the corrected offset before anything paints.
    if (delta != 0 && p.pixels > 0) p.correctBy(delta);
  }
}

/// A reply waiting for another chat's reply to finish with the engine.
class _Queued extends StatelessWidget {
  const _Queued();

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_rounded, size: 16, color: c.textTertiary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Queued · starts when the other reply finishes',
              style: AithraType.bodySmall.copyWith(color: c.textTertiary),
            ),
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
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
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
