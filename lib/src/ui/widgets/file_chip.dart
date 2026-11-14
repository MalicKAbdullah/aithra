import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../../docs/documents.dart';
import '../../services.dart';
import '../aithra_type.dart';

IconData _iconFor(DocInfo d) => switch (d.kind) {
  'PDF' => Icons.picture_as_pdf_outlined,
  'Word' => Icons.article_outlined,
  _ => Icons.description_outlined,
};

/// A document as a compact card: its icon, name and size, with an
/// optional trailing action (remove in the composer).
class FileChip extends StatelessWidget {
  const FileChip({
    required this.doc,
    this.onTap,
    this.trailing,
    this.status,
    super.key,
  });

  final DocInfo doc;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Replaces the size line (a summary in progress).
  final String? status;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Material(
      color: c.surfaceAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        side: BorderSide(color: c.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260, minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.smd,
              AppSpacing.sm,
              AppSpacing.xs,
              AppSpacing.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: c.accentContainer,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusXs),
                  ),
                  child: Icon(_iconFor(doc), size: 20, color: c.accent),
                ),
                const SizedBox(width: AppSpacing.sm + 2),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        doc.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AithraType.label.copyWith(color: c.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        status ?? doc.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AithraType.caption.copyWith(
                          color: status == null ? c.textTertiary : c.accent,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing case final t?) t else const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The documents a message sent, in its footer; tap one to summarise it.
class MessageFiles extends StatelessWidget {
  const MessageFiles({required this.docs, super.key});

  final List<DocInfo> docs;

  @override
  Widget build(BuildContext context) {
    final summarizer = context.services.summarizer;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Align(
        alignment: Alignment.centerRight,
        child: ListenableBuilder(
          listenable: summarizer,
          builder: (context, _) => Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final d in docs)
                FileChip(
                  doc: d,
                  status: switch (summarizer.running[d.id]) {
                    (done: final done, total: final total) when total > 0 =>
                      'Summarising · part ${done + 1} of $total',
                    (done: _, total: _) => 'Summarising…',
                    null => null,
                  },
                  onTap: () => showDocumentSheet(context, d),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A sent document's details and its Summarise action.
Future<void> showDocumentSheet(BuildContext context, DocInfo doc) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) {
        final c = SuiteColors.of(sheet);
        final s = context.services;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.lg,
              AppSpacing.gutter,
              AppSpacing.md,
            ),
            child: ListenableBuilder(
              listenable: s.summarizer,
              builder: (sheet, _) {
                final progress = s.summarizer.running[doc.id];
                final failure = s.summarizer.failures[doc.id];
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_iconFor(doc), color: c.accent),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            doc.name,
                            style: AithraType.h3.copyWith(color: c.textPrimary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      doc.detail,
                      style: AithraType.bodySmall.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      progress != null
                          ? 'Aithra is summarising the whole document in the '
                                'background. You can keep chatting or leave '
                                'the app; the summary arrives in this chat.'
                          : 'Summarise reads the whole document part by part '
                                'in the background and posts a summary in '
                                'this chat.',
                      style: AithraType.body.copyWith(color: c.textSecondary),
                    ),
                    if (failure != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        failure,
                        style: AithraType.bodySmall.copyWith(color: c.negative),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: progress != null
                            ? null
                            : () {
                                unawaited(s.summarizer.summarize(doc));
                                Navigator.pop(sheet);
                              },
                        icon: const Icon(Icons.notes_rounded, size: 18),
                        label: Text(
                          progress == null ? 'Summarise' : 'Summarising…',
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );

/// "Sources · p.3 · p.12" in the footer of a reply that was given document
/// passages, above its actions; tap one to read the passage.
class SourcesRow extends StatelessWidget {
  const SourcesRow({required this.sources, super.key});

  final List<Source> sources;

  Future<void> _show(BuildContext context, Source s) async {
    final passage = await context.services.native.passage(s.docId, s.ord);
    if (passage == null || !context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) {
        final c = SuiteColors.of(sheet);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheet).height * 0.7,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.lg,
                AppSpacing.gutter,
                AppSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${s.name} · ${s.label}',
                    style: AithraType.h3.copyWith(color: c.textPrimary),
                  ),
                  const SizedBox(height: AppSpacing.smd),
                  SelectableText(
                    passage['text']! as String,
                    style: AithraType.body.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final multiple = {for (final s in sources) s.docId}.length > 1;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          Icon(Icons.menu_book_outlined, size: 14, color: c.textTertiary),
          Text(
            'Sources',
            style: AithraType.caption.copyWith(color: c.textTertiary),
          ),
          for (final s in sources)
            InkWell(
              borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
              onTap: () => _show(context, s),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  multiple ? '${s.name} ${s.label}' : s.label,
                  style: AithraType.caption.copyWith(color: c.textSecondary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
