import 'package:core_lock/core_lock.dart';
import 'package:flutter/material.dart';

import 'services.dart';
import 'ui/aithra_type.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/widgets/aithra_mark.dart';

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
        theme: aithraTheme(Brightness.light),
        darkTheme: aithraTheme(Brightness.dark),
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
