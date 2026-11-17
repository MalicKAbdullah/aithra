import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/templates.dart';
import '../../platform/native.dart';
import '../../services.dart';
import '../aithra_type.dart';
import 'composer.dart';
import 'file_chip.dart';
import 'template_chip.dart';

/// Above the composer's field: the files waiting to be sent, a file being
/// read, and chips with what to ask about what is attached or shared.
class AttachmentTray extends StatelessWidget {
  const AttachmentTray({
    required this.controller,
    required this.onSend,
    super.key,
  });

  final ComposerController controller;
  final VoidCallback onSend;

  static Future<String>? _language;

  /// The phone's language, which Translate writes in.
  static Future<String> phoneLanguage(NativeBridge native) =>
      _language ??= native.languages().then((l) => l.first.name);

  Future<void> _use(BuildContext context, PromptTemplate t) async {
    HapticFeedback.selectionClick();
    final c = controller;
    final docs = c.docs.value;
    if (t.id == 'doc.summarise') {
      c.summarise!(docs);
      return;
    }
    final language = t.translates
        ? await phoneLanguage(context.services.native)
        : '';
    final subject = docs.isEmpty
        ? c.text.text
        : docs.length == 1
        ? '"${docs.single.name}"'
        : 'the attached documents';
    c.text.text = t.prompt(subject, language: language);
    c.shared.value = false;
    onSend();
  }

  List<PromptTemplate> _chips(BuildContext context) {
    final c = controller;
    final empty = c.text.text.trim().isEmpty;
    if (empty && c.docs.value.isNotEmpty) return documentTemplates;
    if (empty && c.images.value.isNotEmpty) return imageTemplates;
    if (!empty && c.shared.value) {
      return [
        for (final t in textTemplates)
          if (t.id != 'rewrite' && t.id != 'ask') t,
        ...userTemplates(context.services.settings.promptShortcuts),
      ];
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: Listenable.merge([
        c.docs,
        c.reading,
        c.images,
        c.text,
        c.shared,
      ]),
      builder: (context, _) {
        final chips = _chips(context);
        final reading = c.reading.value;
        final docs = c.docs.value;
        if (chips.isEmpty && reading == null && docs.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (docs.isNotEmpty || reading != null)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    children: [
                      for (final d in docs)
                        Padding(
                          padding: const EdgeInsets.only(right: AppSpacing.xs),
                          child: PreparingFileChip(
                            doc: d,
                            trailing: IconButton(
                              tooltip: 'Remove ${d.name}',
                              iconSize: 18,
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                c.docs.value = [...docs]..remove(d);
                                final s = context.services;
                                s.preparer.drop(d.id);
                                unawaited(s.native.deleteDocument(d.id));
                              },
                            ),
                          ),
                        ),
                      if (reading != null) _Reading(reading),
                    ],
                  ),
                ),
              if (chips.isNotEmpty)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: AppSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      for (final t in chips)
                        Padding(
                          padding: const EdgeInsets.only(right: AppSpacing.sm),
                          child: TemplateChip(
                            template: t,
                            dense: true,
                            onTap: () => _use(context, t),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A file being read in: "Reading · page 3 of 12".
class _Reading extends StatelessWidget {
  const _Reading(this.progress);

  final ({int done, int total}) progress;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final (:done, :total) = progress;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.smd),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: total > 1 ? done / total : null,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            total > 1 ? 'Reading · page ${done + 1} of $total' : 'Reading…',
            style: AithraType.caption.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}
