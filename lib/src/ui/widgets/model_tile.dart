import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';

import '../../models/catalog.dart';
import '../../models/download_state.dart';
import '../../services.dart';
import '../aithra_type.dart';

/// A model with its download state and the action that fits it.
class ModelTile extends StatelessWidget {
  const ModelTile({required this.spec, this.prominent = false, super.key});

  final ModelSpec spec;

  /// Download as the screen's primary action (onboarding) rather than the
  /// tonal button used in the model list.
  final bool prominent;

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
      child: Text(
        text,
        style: AithraType.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );

    final caption = AithraType.caption.copyWith(color: c.textSecondary);
    final badges = [
      if (spec.recommended) badge('Recommended', c.accent),
      if (spec.vision) badge('Images', c.info),
      if (spec.experimental) badge('Experimental', c.warning),
      if (active) badge('In use', c.positive),
    ];

    return VaultCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.smd + 2,
        AppSpacing.md,
        AppSpacing.smd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  spec.name,
                  style: AithraType.title.copyWith(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                formatBytes(spec.sizeBytes),
                style: AithraType.caption.copyWith(
                  color: c.textTertiary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            spec.summary,
            style: AithraType.bodySmall.copyWith(color: c.textSecondary),
          ),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(runSpacing: AppSpacing.xs, children: badges),
          ],
          const SizedBox(height: AppSpacing.smd),
          switch (state) {
            NotDownloaded() => _ActionRow(
              status: Text(
                '${formatBytes(spec.sizeBytes)} download',
                style: caption,
              ),
              action: (prominent ? FilledButton.icon : FilledButton.tonalIcon)(
                onPressed: spec.url.isEmpty
                    ? null
                    : () => s.models.download(spec),
                style: _compact,
                icon: const Icon(Icons.download_rounded, size: 18),
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
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppProgressBar(value: fraction ?? 0, height: 6),
                  _ActionRow(
                    status: Text.rich(
                      TextSpan(
                        children: [
                          if (fraction != null)
                            TextSpan(
                              text: '${(fraction * 100).floor()}%  ',
                              style: TextStyle(
                                color: c.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          TextSpan(
                            text:
                                waitingReason ??
                                '${formatBytes(downloaded)} of ${formatBytes(total)}',
                          ),
                        ],
                      ),
                      style: caption.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    action: TextButton(
                      onPressed: () => s.models.cancelDownload(spec),
                      style: _trailingText,
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            DownloadFailed(:final message) => _ActionRow(
              status: Text(message, style: caption.copyWith(color: c.negative)),
              action: TextButton(
                onPressed: () => s.models.download(spec),
                style: _trailingText,
                child: const Text('Try again'),
              ),
            ),
            Ready() =>
              calibrating != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppProgressBar(
                          value: calibrating.total == 0
                              ? 0
                              : calibrating.done / calibrating.total,
                          height: 6,
                        ),
                        _ActionRow(
                          status: Text(
                            'Tuning for your phone… testing ${calibrating.label}',
                            style: caption,
                          ),
                        ),
                      ],
                    )
                  : spec.kind == ModelKind.embedding
                  ? _RecallStatus(onDelete: () => _confirmDelete(context, spec))
                  : _ActionRow(
                      status: active
                          ? Row(
                              children: [
                                Icon(
                                  Icons.check_circle_rounded,
                                  size: 16,
                                  color: c.positive,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    _backendLine(context, spec),
                                    style: caption,
                                  ),
                                ),
                              ],
                            )
                          : FilledButton(
                              onPressed: () => s.assistant.select(spec),
                              style: _compact,
                              child: const Text('Use'),
                            ),
                      action: IconButton(
                        tooltip: 'Delete',
                        // Icon flush with the card's right text edge.
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 44,
                        ),
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(
                          alignment: Alignment.centerRight,
                        ),
                        iconSize: 22,
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          color: c.textSecondary,
                        ),
                        onPressed: () => _confirmDelete(context, spec),
                      ),
                    ),
          },
        ],
      ),
    );
  }

  static final _compact = FilledButton.styleFrom(
    minimumSize: const Size(64, 40),
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
  );

  /// A trailing text action whose label ends on the card's text edge.
  static final _trailingText = TextButton.styleFrom(
    padding: const EdgeInsets.only(left: AppSpacing.smd),
    minimumSize: const Size(48, 40),
    alignment: Alignment.centerRight,
  );

  String _backendLine(BuildContext context, ModelSpec spec) {
    final b = context.services.assistant.backendFor(spec);
    return b == null ? 'Ready' : 'Ready · runs on ${b.label}';
  }

  Future<void> _confirmDelete(BuildContext context, ModelSpec spec) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${spec.name}?'),
        content: Text(
          spec.kind == ModelKind.embedding
              ? 'Frees ${formatBytes(spec.sizeBytes)}. Aithra stops bringing '
                    'up your other chats; the chats themselves stay.'
              : 'Frees ${formatBytes(spec.sizeBytes)}. Your chats stay.',
        ),
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
      if (spec.kind == ModelKind.chat) await s.engine.release();
      await s.models.delete(spec);
    }
  }
}

/// Status on the left, one action flush with the card's right text edge.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.status, this.action});

  final Widget status;
  final Widget? action;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 40),
    child: Row(
      children: [
        Expanded(
          child: Align(alignment: Alignment.centerLeft, child: status),
        ),
        if (action != null) ...[const SizedBox(width: AppSpacing.sm), action!],
      ],
    ),
  );
}

/// The embedding model's state: how much is indexed, or why recall is not
/// working, with a way to try again.
class _RecallStatus extends StatelessWidget {
  const _RecallStatus({required this.onDelete});

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final recall = context.services.recall;
    final caption = AithraType.caption.copyWith(color: c.textSecondary);
    return ListenableBuilder(
      listenable: recall,
      builder: (context, _) {
        final failure = recall.failure;
        if (failure != null) {
          return _ActionRow(
            status: Text(
              'Not working: $failure',
              style: caption.copyWith(color: c.negative),
            ),
            action: TextButton(
              onPressed: recall.retry,
              style: ModelTile._trailingText,
              child: const Text('Try again'),
            ),
          );
        }
        final indexed = recall.indexed;
        final total = recall.total;
        return _ActionRow(
          status: Row(
            children: [
              Icon(Icons.check_circle_rounded, size: 16, color: c.positive),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  indexed == null || total == null
                      ? 'On'
                      : indexed >= total
                      ? 'On · all $total messages indexed'
                      : 'On · $indexed of $total messages indexed',
                  style: caption,
                ),
              ),
            ],
          ),
          action: IconButton(
            tooltip: 'Delete',
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(alignment: Alignment.centerRight),
            iconSize: 22,
            icon: Icon(Icons.delete_outline_rounded, color: c.textSecondary),
            onPressed: onDelete,
          ),
        );
      },
    );
  }
}
