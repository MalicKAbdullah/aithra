import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../../chat/templates.dart';
import '../aithra_type.dart';

/// A rounded chip for a [PromptTemplate], filled with the accent while it
/// is the one answered.
class TemplateChip extends StatelessWidget {
  const TemplateChip({
    required this.template,
    required this.onTap,
    this.selected = false,
    this.enabled = true,
    this.dense = false,
    super.key,
  });

  final PromptTemplate template;
  final VoidCallback onTap;
  final bool selected;
  final bool enabled;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final fg = selected ? c.onAccent : c.textPrimary;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: selected ? c.accent : c.surfaceAlt,
        shape: StadiumBorder(
          side: BorderSide(color: selected ? c.accent : c.border),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: AppSpacing.smd,
              vertical: dense ? AppSpacing.xs + 2 : AppSpacing.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(template.icon, size: 16, color: fg),
                const SizedBox(width: 6),
                Text(
                  template.label,
                  style: AithraType.label.copyWith(color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
