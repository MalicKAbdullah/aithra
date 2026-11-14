import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/prompt_shortcut.dart';
import '../../services.dart';
import '../aithra_type.dart';
import '../screens/prompt_shortcuts_screen.dart';

/// The user's prompt shortcuts as chips, centred and wrapping, with a chip
/// at the end that opens the editor. Rebuilds when the list changes.
class PromptShortcutChips extends StatelessWidget {
  const PromptShortcutChips({required this.onPick, super.key});

  final ValueChanged<PromptShortcut> onPick;

  @override
  Widget build(BuildContext context) {
    final settings = context.services.settings;
    final c = SuiteColors.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      side: BorderSide(color: c.border),
    );
    final label = AithraType.label.copyWith(color: c.textPrimary);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Wrap(
        alignment: WrapAlignment.center,
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (final p in settings.promptShortcuts)
            ActionChip(
              label: Text(p.label),
              labelStyle: label,
              backgroundColor: c.surface,
              shape: shape,
              onPressed: () {
                HapticFeedback.selectionClick();
                onPick(p);
              },
            ),
          ActionChip(
            avatar: Icon(Icons.tune_rounded, size: 16, color: c.textSecondary),
            label: Text(
              settings.promptShortcuts.isEmpty ? 'Add shortcuts' : 'Edit',
            ),
            labelStyle: label.copyWith(color: c.textSecondary),
            backgroundColor: c.background,
            shape: shape,
            tooltip: 'Edit prompt shortcuts',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const PromptShortcutsScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
