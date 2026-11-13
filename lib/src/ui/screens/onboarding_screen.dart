import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import '../../models/catalog.dart';
import '../../models/download_state.dart';
import '../../services.dart';
import '../aithra_type.dart';
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

  static bool _modelReady(BuildContext context) {
    final s = context.services;
    return s.assistant.activeModel != null ||
        s.models.availability(defaultModel) is Ready;
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
                  if (_page < 2)
                    FilledButton(onPressed: _next, child: const Text('Next'))
                  else
                    // Until a model is on the phone the card's Download is
                    // the page's one primary action; leaving is secondary.
                    ListenableBuilder(
                      listenable: Listenable.merge([
                        context.services.models,
                        context.services.assistant,
                      ]),
                      builder: (context, _) => _modelReady(context)
                          ? FilledButton(
                              onPressed: _next,
                              child: const Text('Start chatting'),
                            )
                          : TextButton(
                              onPressed: _next,
                              child: const Text('Download later'),
                            ),
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
    required this.hero,
    required this.title,
    required this.body,
    this.extra,
  });

  final Widget hero;
  final String title;
  final String body;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    // Content sits in the visual middle when it fits and scrolls when it
    // does not (large text, small phones).
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppSpacing.lg),
              SizedBox.square(dimension: _heroSize, child: hero),
              const SizedBox(height: AppSpacing.lg),
              Text(
                title,
                style: AithraType.display.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: AppSpacing.smd),
              Text(
                body,
                style: AithraType.body.copyWith(
                  color: c.textSecondary,
                  fontSize: 15.5,
                ),
              ),
              if (extra != null) ...[
                const SizedBox(height: AppSpacing.lg),
                extra!,
              ],
              // Lifts the block slightly above centre, where the eye rests.
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

const double _heroSize = 64;

/// A hero tile matching [AithraMark]'s size and shape.
class _HeroIcon extends StatelessWidget {
  const _HeroIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.accentContainer,
        borderRadius: BorderRadius.circular(_heroSize * 0.28),
      ),
      child: Icon(icon, size: 30, color: c.accent),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) => const _Page(
    hero: AithraMark(size: _heroSize),
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
      padding: const EdgeInsets.only(bottom: AppSpacing.smd + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: c.accent, size: 20),
          const SizedBox(width: AppSpacing.smd),
          Expanded(
            child: Text(
              text,
              style: AithraType.body.copyWith(color: c.textPrimary),
            ),
          ),
        ],
      ),
    );
    return _Page(
      hero: const _HeroIcon(Icons.shield_outlined),
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
      hero: const _HeroIcon(Icons.download_rounded),
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
            builder: (context, _) =>
                ModelTile(spec: defaultModel, prominent: true),
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
