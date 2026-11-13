import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/native.dart';
import '../aithra_type.dart';

/// Hosts a [ReportScreen] before the app's services exist: no lock, no
/// stored appearance, only the theme.
class ReportApp extends StatelessWidget {
  const ReportApp({required this.home, super.key});

  final Widget home;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Aithra',
    debugShowCheckedModeBanner: false,
    theme: aithraTheme(Brightness.light),
    darkTheme: aithraTheme(Brightness.dark),
    home: home,
  );
}

/// A problem report the user can copy or share without a computer: the
/// crash from the previous run, or why startup failed this time.
class ReportScreen extends StatelessWidget {
  const ReportScreen({
    required this.native,
    required this.title,
    required this.message,
    required this.report,
    this.onContinue,
    super.key,
  });

  /// Shown on launch when the previous run ended in a crash.
  factory ReportScreen.lastCrash({
    required NativeBridge native,
    required String report,
    required VoidCallback onContinue,
  }) => ReportScreen(
    native: native,
    title: 'Aithra closed unexpectedly last time',
    message:
        'This report stays on your phone. Copy or share it to help fix the '
        'problem; it holds technical details, not your chats.',
    report: report,
    onContinue: onContinue,
  );

  /// Shown instead of the app when startup fails.
  factory ReportScreen.startupFailed({
    required NativeBridge native,
    required String report,
  }) => ReportScreen(
    native: native,
    title: "Aithra couldn't start",
    message:
        'Something went wrong while opening your data. Copy or share these '
        'details to help fix the problem.',
    report: report,
  );

  final NativeBridge native;
  final String title;
  final String message;
  final String report;

  /// Null when there is no way forward from this screen.
  final VoidCallback? onContinue;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: report));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Report copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.xl,
            AppSpacing.gutter,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.accentContainer,
                    borderRadius: BorderRadius.circular(64 * 0.28),
                  ),
                  child: SizedBox.square(
                    dimension: 64,
                    child: Icon(
                      Icons.report_gmailerrorred_rounded,
                      size: 30,
                      color: c.accent,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                title,
                style: AithraType.display.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: AppSpacing.smd),
              Text(
                message,
                style: AithraType.body.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                    border: Border.all(color: c.border),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: SelectableText(
                      report,
                      style: AithraType.code.copyWith(
                        color: c.textPrimary,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _copy(context),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Copy'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => native.shareText(report),
                      icon: const Icon(Icons.share_rounded, size: 18),
                      label: const Text('Share'),
                    ),
                  ),
                ],
              ),
              if (onContinue case final proceed?) ...[
                const SizedBox(height: AppSpacing.sm),
                FilledButton(onPressed: proceed, child: const Text('Continue')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when the Keystore lost the key to the data on the phone: the data
/// cannot be decrypted, and the only way forward is to erase it.
class DataLostScreen extends StatelessWidget {
  const DataLostScreen({required this.onErase, super.key});

  final Future<void> Function() onErase;

  Future<void> _confirm(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Erase chats and memories?'),
        content: const Text(
          'They cannot be unlocked any more. Downloaded models stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Erase'),
          ),
        ],
      ),
    );
    if (ok ?? false) await onErase();
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.xl,
            AppSpacing.gutter,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Text(
                "Aithra can't unlock your data",
                style: AithraType.display.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: AppSpacing.smd),
              Text(
                "The phone's secure key store no longer has the key that "
                'encrypts your chats and memories, so they cannot be read. '
                'This can happen after a reset of the phone\'s security '
                'settings. Erase them to start over.',
                style: AithraType.body.copyWith(color: c.textSecondary),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => _confirm(context),
                child: const Text('Erase and start over'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
