import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../aithra_type.dart';

/// A quiet group heading that sits on the same left edge as the cards
/// below it.
class SectionLabel extends StatelessWidget {
  const SectionLabel(
    this.title, {
    this.first = false,
    this.trailing,
    super.key,
  });

  final String title;

  /// The first section on a screen needs less room above it.
  final bool first;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Padding(
      padding: EdgeInsets.only(
        top: first ? AppSpacing.xs : AppSpacing.lg,
        bottom: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: AithraType.section.copyWith(color: c.textSecondary),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
