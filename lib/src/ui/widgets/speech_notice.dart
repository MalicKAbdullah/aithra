import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../voice/speech_service.dart';
import '../aithra_type.dart';

/// The speech model's state under the voice orb or in a snack bar: what
/// Android is doing, its progress, and the one action that helps.
class SpeechNoticeView extends StatelessWidget {
  const SpeechNoticeView({
    required this.speech,
    required this.notice,
    this.inverse = false,
    super.key,
  });

  final SpeechService speech;
  final SpeechNotice notice;

  /// In a snack bar, whose background is inverted.
  final bool inverse;

  static String actionLabel(SpeechAction action) => switch (action) {
    SpeechAction.download => 'Download it',
    SpeechAction.openSpeechSettings => 'Open language settings',
  };

  Future<void> _copyDetails(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: speech.report.toString()));
    HapticFeedback.selectionClick();
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Speech details copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textColor = inverse
        ? scheme.onInverseSurface
        : notice.error
        ? c.negative
        : c.textSecondary;
    final buttonColor = inverse ? scheme.inversePrimary : null;
    final action = notice.action;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: inverse
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Text(
          notice.text,
          textAlign: inverse ? TextAlign.start : TextAlign.center,
          style: AithraType.bodySmall.copyWith(color: textColor),
        ),
        if (notice.progress != null || notice.busy) ...[
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: notice.progress,
              minHeight: 3,
            ),
          ),
        ],
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            if (action != null)
              TextButton(
                onPressed: () => speech.run(action),
                style: TextButton.styleFrom(foregroundColor: buttonColor),
                child: Text(actionLabel(action)),
              ),
            if ((notice.error || speech.languageMissing) &&
                speech.report != null)
              TextButton(
                onPressed: () => _copyDetails(context),
                style: TextButton.styleFrom(foregroundColor: buttonColor),
                child: const Text('Copy details'),
              ),
          ],
        ),
      ],
    );
  }
}
