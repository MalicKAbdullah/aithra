import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../../models/catalog.dart';
import '../../services.dart';
import '../widgets/aithra_mark.dart';
import '../widgets/model_tile.dart';
import 'models_screen.dart';

/// Three short pages: what Aithra is, how it keeps things private, and the
/// one-time model download.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < 2) {
      _pages.nextPage(duration: AppMotion.base, curve: AppMotion.emphasized);
    } else {
      context.services.settings.update((s) => s.onboarded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (p) => setState(() => _page = p),
                children: const [_Intro(), _Privacy(), _Download()],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                0,
                AppSpacing.gutter,
                AppSpacing.lg,
              ),
              child: Row(
                children: [
                  for (var i = 0; i < 3; i++)
                    AnimatedContainer(
                      duration: AppMotion.fast,
                      margin: const EdgeInsets.only(right: 6),
                      width: i == _page ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _page ? c.accent : c.border,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _next,
                    child: Text(_page < 2 ? 'Next' : 'Start chatting'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({
    required this.top,
    required this.title,
    required this.body,
    this.extra,
  });

  final Widget top;
  final String title;
  final String body;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.xxl,
        AppSpacing.gutter,
        AppSpacing.lg,
      ),
      children: [
        Align(alignment: Alignment.centerLeft, child: top),
        const SizedBox(height: AppSpacing.xl),
        Text(title, style: AppTextStyles.h1.copyWith(color: c.textPrimary)),
        const SizedBox(height: AppSpacing.md),
        Text(
          body,
          style: AppTextStyles.body.copyWith(
            color: c.textSecondary,
            height: 1.5,
          ),
        ),
        if (extra != null) ...[const SizedBox(height: AppSpacing.xl), extra!],
      ],
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) => const _Page(
    top: AithraMark(size: 72),
    title: 'Meet Aithra',
    body:
        'An AI assistant that lives on your phone. Ask questions, think '
        'things through, show it a photo, or just talk to it hands-free. '
        'It remembers what you tell it to — and nothing else.',
  );
}

class _Privacy extends StatelessWidget {
  const _Privacy();

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    Widget point(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: c.accent, size: 22),
          const SizedBox(width: AppSpacing.smd),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.bodyMedium.copyWith(color: c.textPrimary),
            ),
          ),
        ],
      ),
    );
    return _Page(
      top: Icon(Icons.shield_outlined, size: 64, color: c.accent),
      title: 'Private by design',
      body: 'Aithra thinks on your phone, not in the cloud.',
      extra: Column(
        children: [
          point(
            Icons.wifi_off_rounded,
            'Works offline. The only time it uses the internet is to download its model, once.',
          ),
          point(
            Icons.lock_outline_rounded,
            'Chats, photos and memories are encrypted on this phone.',
          ),
          point(
            Icons.fingerprint_rounded,
            'Add an app lock with your fingerprint in Settings.',
          ),
        ],
      ),
    );
  }
}

class _Download extends StatelessWidget {
  const _Download();

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return _Page(
      top: Icon(
        Icons.download_rounded,
        size: 64,
        color: SuiteColors.of(context).accent,
      ),
      title: 'Download its brain',
      body:
          'Aithra needs a model file. Gemma 4 E2B is the best fit for most '
          'phones. The download continues if you leave the app; once it '
          "finishes, Aithra tunes itself to your phone's chip.",
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListenableBuilder(
            listenable: s.models,
            builder: (context, _) => ModelTile(spec: defaultModel),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ModelsScreen()),
            ),
            child: const Text('Other models or import a file'),
          ),
        ],
      ),
    );
  }
}
