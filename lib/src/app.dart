import 'package:core_lock/core_lock.dart';
import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

import 'services.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/widgets/aithra_mark.dart';

/// Aithra's accent: ember — warm, and distinct from the other Offlyne apps.
const AppAccent aithraAccent = AppAccent(
  light: Color(0xFFC2410C),
  dark: Color(0xFFFF9A5C),
  containerLight: Color(0xFFFFF1E8),
  containerDark: Color(0xFF3A2216),
  onAccentLight: Color(0xFFFFFFFF),
  onAccentDark: Color(0xFF1A0E07),
);

class AithraApp extends StatelessWidget {
  const AithraApp({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    return ListenableBuilder(
      listenable: s.appearance,
      builder: (context, _) => MaterialApp(
        title: 'Aithra',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(Brightness.light, accent: aithraAccent),
        darkTheme: AppTheme.build(Brightness.dark, accent: aithraAccent),
        themeMode: s.appearance.mode,
        // The lock cover sits above the navigator, so unlocking returns the
        // user exactly where they were.
        builder: (context, child) => AppLockGate(
          controller: s.lock,
          appMark: const AithraMark(size: 56),
          child: child ?? const SizedBox.shrink(),
        ),
        home: ListenableBuilder(
          listenable: s.settings,
          builder: (context, _) => s.settings.onboarded
              ? const HomeScreen()
              : const OnboardingScreen(),
        ),
      ),
    );
  }
}
