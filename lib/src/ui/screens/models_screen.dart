import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';

import '../../models/catalog.dart';
import '../../models/download_state.dart';
import '../../services.dart';
import '../widgets/model_tile.dart';

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      body: ListenableBuilder(
        listenable: s.models,
        builder: (context, _) {
          final imported = s.models.importedModels;
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              0,
              AppSpacing.gutter,
              AppSpacing.xxl,
            ),
            children: [
              Text(
                'Using ${formatBytes(s.models.usedBytes)} · '
                '${formatBytes(s.models.freeBytes)} free',
                style: AppTextStyles.bodySmall.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.md),
              for (final m in catalog) ...[
                ModelTile(spec: m),
                const SizedBox(height: AppSpacing.smd),
              ],
              if (imported.isNotEmpty) ...[
                const SectionHeader(title: 'Imported'),
                for (final m in imported) ...[
                  ModelTile(spec: m),
                  const SizedBox(height: AppSpacing.smd),
                ],
              ],
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: s.models.importing ? null : () => _import(context),
                icon: const Icon(Icons.file_open_outlined),
                label: Text(
                  s.models.importing
                      ? 'Importing… ${s.models.importProgress == null ? '' : '${(s.models.importProgress! * 100).round()}%'}'
                      : 'Import a .litertlm or .gguf file',
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: c.textTertiary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Models download from Hugging Face. That is the only '
                      'network access Aithra has; your chats never leave the phone.',
                      style: AppTextStyles.caption.copyWith(
                        color: c.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _import(BuildContext context) async {
    final s = context.services;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final spec = await s.models.import();
      if (spec != null) await s.assistant.select(spec);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }
}
