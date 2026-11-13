import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../../services.dart';
import '../aithra_type.dart';

/// What the user wants Aithra to know about them and how it should respond.
/// Both go into every chat's hidden system prompt, within its token budget,
/// and are stored encrypted with the other settings.
class CustomInstructionsScreen extends StatefulWidget {
  const CustomInstructionsScreen({super.key});

  /// Characters per field; together about a sixth of a 4K context at worst.
  static const int maxChars = 1500;

  @override
  State<CustomInstructionsScreen> createState() =>
      _CustomInstructionsScreenState();
}

class _CustomInstructionsScreenState extends State<CustomInstructionsScreen> {
  late final _about = TextEditingController(
    text: context.services.settings.aboutUser,
  );
  late final _style = TextEditingController(
    text: context.services.settings.replyStyle,
  );

  bool get _changed {
    final s = context.services.settings;
    return _about.text.trim() != s.aboutUser ||
        _style.text.trim() != s.replyStyle;
  }

  @override
  void dispose() {
    _about.dispose();
    _style.dispose();
    super.dispose();
  }

  Future<void> _save() {
    final about = _about.text.trim();
    final style = _style.text.trim();
    return context.services.settings.update(
      (s) => s
        ..aboutUser = about
        ..replyStyle = style,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return PopScope(
      // Leaving keeps what was typed, like every other setting here.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _changed) _save();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Custom instructions'),
          actions: [
            ListenableBuilder(
              listenable: Listenable.merge([_about, _style]),
              builder: (context, _) => TextButton(
                onPressed: _changed
                    ? () async {
                        await _save();
                        if (context.mounted) Navigator.of(context).pop();
                      }
                    : null,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.xs,
            AppSpacing.gutter,
            AppSpacing.xxl,
          ),
          children: [
            Text(
              'Aithra reads these before every chat. They stay encrypted on '
              'this phone.',
              style: AithraType.bodySmall.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            _Field(
              label: 'What should Aithra know about you?',
              hint:
                  'e.g. I teach secondary-school physics in Leeds and I am '
                  'learning Spanish.',
              controller: _about,
            ),
            const SizedBox(height: AppSpacing.lg),
            _Field(
              label: 'How should Aithra respond?',
              hint:
                  'e.g. Be brief and direct. Show the steps when you solve '
                  'maths problems. Use metric units.',
              controller: _style,
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.hint,
    required this.controller,
  });

  final String label;
  final String hint;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AithraType.title.copyWith(color: c.textPrimary)),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: controller,
          minLines: 4,
          maxLines: 10,
          maxLength: CustomInstructionsScreen.maxChars,
          textCapitalization: TextCapitalization.sentences,
          style: AithraType.body.copyWith(color: c.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            hintMaxLines: 3,
            hintStyle: AithraType.body.copyWith(color: c.textTertiary),
            filled: true,
            fillColor: c.surfaceAlt,
            contentPadding: const EdgeInsets.all(AppSpacing.md),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              borderSide: BorderSide(color: c.accent.withValues(alpha: 0.6)),
            ),
            counterStyle: AithraType.caption.copyWith(color: c.textTertiary),
          ),
        ),
      ],
    );
  }
}
