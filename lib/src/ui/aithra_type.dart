import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';

/// Aithra's type scale. Chat reading is dense and calm, so Aithra sets its
/// own sizes here instead of the suite's display-oriented scale; families
/// and colours still come from core_theme. Weights stay at w400–w600.
abstract final class AithraType {
  static const String _sans = AppTextStyles.fontFamily;
  static const String _mono = AppTextStyles.monoFamily;

  /// Message text, user and model alike.
  static const body = TextStyle(
    fontFamily: _sans,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
    height: 1.45,
  );

  static const bodySmall = TextStyle(
    fontFamily: _sans,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  static const caption = TextStyle(
    fontFamily: _sans,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.1,
    height: 1.33,
  );

  /// List and card titles.
  static const title = TextStyle(
    fontFamily: _sans,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 1.3,
  );

  static const label = TextStyle(
    fontFamily: _sans,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.3,
  );

  static const labelStrong = TextStyle(
    fontFamily: _sans,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  /// Group headings inside a screen ("Assistant", "Diagnostics").
  static const section = TextStyle(
    fontFamily: _sans,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
    height: 1.3,
  );

  static const appBarTitle = TextStyle(
    fontFamily: _sans,
    fontSize: 19,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.25,
  );

  /// The chat screen's two-line title.
  static const chatTitle = TextStyle(
    fontFamily: _sans,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.25,
  );

  /// Onboarding page titles.
  static const display = TextStyle(
    fontFamily: AppTextStyles.displayFamily,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    height: 1.15,
  );

  static const h1 = TextStyle(
    fontFamily: _sans,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.3,
  );

  static const h2 = TextStyle(
    fontFamily: _sans,
    fontSize: 16.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.3,
  );

  static const h3 = TextStyle(
    fontFamily: _sans,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  /// Code blocks and inline code: 13 sp fits ~45 columns on a phone.
  static const code = TextStyle(
    fontFamily: _mono,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );

  /// Tabular figures for metrics.
  static const number = TextStyle(
    fontFamily: _sans,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Aithra's accent: ember — warm, and distinct from the other Offlyne apps.
const AppAccent aithraAccent = AppAccent(
  light: Color(0xFFC2410C),
  dark: Color(0xFFFF9A5C),
  containerLight: Color(0xFFFFF1E8),
  containerDark: Color(0xFF3A2216),
  onAccentLight: Color(0xFFFFFFFF),
  onAccentDark: Color(0xFF1A0E07),
);

/// The suite theme with Aithra's denser type and controls.
ThemeData aithraTheme(Brightness brightness) {
  final base = AppTheme.build(brightness, accent: aithraAccent);
  final c = base.extension<SuiteColors>()!;
  final button = WidgetStatePropertyAll(
    AppTextStyles.button.copyWith(fontSize: 14.5),
  );
  const buttonSize = WidgetStatePropertyAll(Size(64, 44));
  const buttonPadding = WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: AppSpacing.mdl),
  );
  return base.copyWith(
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: AithraType.appBarTitle.copyWith(color: c.textPrimary),
      toolbarHeight: 56,
      // IconButtons are 48 wide around a 24 icon; 8 more puts the last icon's
      // edge on the 20 dp gutter.
      actionsPadding: const EdgeInsets.only(right: AppSpacing.gutter - 12),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: AithraType.title.copyWith(color: c.textPrimary),
      subtitleTextStyle: AithraType.bodySmall.copyWith(color: c.textSecondary),
      minVerticalPadding: AppSpacing.sm,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style!.copyWith(
        textStyle: button,
        minimumSize: buttonSize,
        padding: buttonPadding,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style!.copyWith(
        textStyle: button,
        minimumSize: buttonSize,
        padding: buttonPadding,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style!.copyWith(
        textStyle: WidgetStatePropertyAll(
          AithraType.labelStrong.copyWith(fontSize: 14.5),
        ),
      ),
    ),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
      extendedTextStyle: AithraType.labelStrong.copyWith(fontSize: 15),
      extendedSizeConstraints: const BoxConstraints.tightFor(height: 52),
      sizeConstraints: const BoxConstraints.tightFor(width: 56, height: 56),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      contentTextStyle: AithraType.bodySmall.copyWith(
        fontSize: 14,
        color: base.colorScheme.onInverseSurface,
      ),
    ),
  );
}
