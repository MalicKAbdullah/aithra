import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/markdown.dart';

/// Renders a reply's Markdown. Parsed blocks are cached per text, so a
/// finished message is parsed once; a streaming one re-parses only when its
/// text changes (once per frame at most).
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.text, {super.key});

  final String text;

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
    final base = AppTextStyles.body.copyWith(color: c.textPrimary, height: 1.5);
    final blocks = _parse(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : AppSpacing.sm),
            child: _block(context, blocks[i], base, c),
          ),
      ],
    );
  }

  Widget _block(
    BuildContext context,
    MdBlock b,
    TextStyle base,
    SuiteColors c,
  ) => switch (b) {
    MdHeading(:final level, :final text) => Text.rich(
      _inline(text, base, c),
      style:
          (level <= 1
                  ? AppTextStyles.h3
                  : level == 2
                  ? AppTextStyles.h4
                  : AppTextStyles.labelStrong)
              .copyWith(color: c.textPrimary),
    ),
    MdParagraph(:final text) => Text.rich(_inline(text, base, c)),
    MdListItem(:final text, :final marker, :final indent) => Padding(
      padding: EdgeInsets.only(left: indent * 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(marker, style: base.copyWith(color: c.textSecondary)),
          ),
          Expanded(child: Text.rich(_inline(text, base, c))),
        ],
      ),
    ),
    MdQuote(:final text) => Container(
      padding: const EdgeInsets.only(left: AppSpacing.smd),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.border, width: 3)),
      ),
      child: Text.rich(_inline(text, base.copyWith(color: c.textSecondary), c)),
    ),
    MdRule() => Divider(color: c.hairline),
    MdCode(:final language, :final code) => CodeBlock(
      language: language,
      code: code,
    ),
  };

  TextSpan _inline(String text, TextStyle base, SuiteColors c) => TextSpan(
    style: base,
    children: [
      for (final s in parseInline(text))
        TextSpan(
          text: s.text,
          style: switch (s.style) {
            InlineStyle.plain => null,
            InlineStyle.bold => const TextStyle(fontWeight: FontWeight.w700),
            InlineStyle.italic => const TextStyle(fontStyle: FontStyle.italic),
            InlineStyle.boldItalic => const TextStyle(
              fontWeight: FontWeight.w700,
              fontStyle: FontStyle.italic,
            ),
            InlineStyle.code => AppTextStyles.code.copyWith(
              color: c.textPrimary,
              backgroundColor: c.surfaceAlt,
            ),
            InlineStyle.link => TextStyle(
              color: c.accent,
              decoration: TextDecoration.underline,
            ),
          },
        ),
    ],
  );
}

class CodeBlock extends StatelessWidget {
  const CodeBlock({required this.language, required this.code, super.key});

  final String language;
  final String code;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.smd, 2, 2, 0),
            child: Row(
              children: [
                Text(
                  language.isEmpty ? 'code' : language,
                  style: AppTextStyles.caption.copyWith(color: c.textTertiary),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Copy code',
                  iconSize: 18,
                  icon: const Icon(Icons.content_copy_rounded),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    HapticFeedback.selectionClick();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied')),
                    );
                  },
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.smd,
              0,
              AppSpacing.smd,
              AppSpacing.smd,
            ),
            child: Text(
              code,
              style: AppTextStyles.code.copyWith(
                color: c.textPrimary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
