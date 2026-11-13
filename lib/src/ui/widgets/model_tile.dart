import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';

import '../../models/catalog.dart';
import '../../models/download_state.dart';
import '../../services.dart';

/// A model with its download state and the action that fits it.
class ModelTile extends StatelessWidget {
  const ModelTile({required this.spec, super.key});

  final ModelSpec spec;

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.models, s.assistant]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final s = context.services;
    final c = SuiteColors.of(context);
    final state = s.models.availability(spec);
    final active = s.assistant.activeModel?.id == spec.id;
    final calibrating = s.assistant.calibrating?.model.id == spec.id
        ? s.assistant.calibrating
        : null;

    Widget badge(String text, Color color) => Container(
      margin: const EdgeInsets.only(right: AppSpacing.xs),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      ),
      child: Text(text, style: AppTextStyles.caption.copyWith(color: color)),
    );

    return VaultCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  spec.name,
                  style: AppTextStyles.h4.copyWith(color: c.textPrimary),
                ),
              ),
              Text(
                formatBytes(spec.sizeBytes),
                style: AppTextStyles.numberSmall.copyWith(
                  color: c.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            spec.summary,
            style: AppTextStyles.bodySmall.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            children: [
              if (spec.recommended) badge('Recommended', c.accent),
              if (spec.vision) badge('Images', c.info),
              if (spec.experimental) badge('Experimental', c.warning),
              if (active) badge('In use', c.positive),
            ],
          ),
          const SizedBox(height: AppSpacing.smd),
          switch (state) {
            NotDownloaded() => Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: spec.url.isEmpty
                    ? null
                    : () => s.models.download(spec),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Download'),
              ),
            ),
            Downloading(
              :final fraction,
              :final downloaded,
              :final total,
              :final waitingReason,
            ) =>
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppProgressBar(value: fraction ?? 0),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          waitingReason ??
                              '${formatBytes(downloaded)} of ${formatBytes(total)}',
                          style: AppTextStyles.caption.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => s.models.cancelDownload(spec),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ],
              ),
            DownloadFailed(:final message) => Row(
              children: [
                Expanded(
                  child: Text(
                    message,
                    style: AppTextStyles.caption.copyWith(color: c.negative),
                  ),
                ),
                TextButton(
                  onPressed: () => s.models.download(spec),
                  child: const Text('Try again'),
                ),
              ],
            ),
            Ready() =>
              calibrating != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppProgressBar(
                          value: calibrating.total == 0
                              ? 0
                              : calibrating.done / calibrating.total,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          'Tuning for your phone… testing ${calibrating.label}',
                          style: AppTextStyles.caption.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        if (!active)
                          FilledButton(
                            onPressed: () => s.assistant.select(spec),
                            child: const Text('Use'),
                          )
                        else
                          Text(
                            _backendLine(context, spec),
                            style: AppTextStyles.caption.copyWith(
                              color: c.textSecondary,
                            ),
                          ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => _confirmDelete(context, spec),
                        ),
                      ],
                    ),
          },
        ],
      ),
    );
  }

  String _backendLine(BuildContext context, ModelSpec spec) {
    final b = context.services.assistant.backendFor(spec);
    return b == null ? 'Ready' : 'Ready · runs on ${b.label}';
  }

  Future<void> _confirmDelete(BuildContext context, ModelSpec spec) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${spec.name}?'),
        content: Text('Frees ${formatBytes(spec.sizeBytes)}. Your chats stay.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      final s = context.services;
      await s.engine.release();
      await s.models.delete(spec);
    }
  }
}
