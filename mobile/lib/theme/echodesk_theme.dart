import 'package:flutter/material.dart';

class EchoDeskColors {
  EchoDeskColors._();

  static const Color background = Color(0xFFFBFAF8);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceSoft = Color(0xFFF4F1EE);
  static const Color surfaceMuted = Color(0xFFEDE9E4);
  static const Color ink = Color(0xFF151821);
  static const Color muted = Color(0xFF626873);
  static const Color soft = Color(0xFF8B9099);
  static const Color line = Color(0xFFE6E0DA);
  static const Color lineStrong = Color(0xFFCFC6BD);
  static const Color brand = Color(0xFF174061);
  static const Color brandTeal = Color(0xFF2F9C9D);
  static const Color brandSoft = Color(0xFFE6F3F2);
  static const Color accent = Color(0xFF57609A);
  static const Color success = Color(0xFF4F8663);
  static const Color warning = Color(0xFFA87635);
  static const Color warningSoft = Color(0xFFFFE6B8);
}

class EchoDeskSpacing {
  EchoDeskSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

class EchoDeskRadii {
  EchoDeskRadii._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
}

class EchoDeskTheme {
  EchoDeskTheme._();

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: EchoDeskColors.brand,
      brightness: Brightness.light,
    ).copyWith(
      primary: EchoDeskColors.brand,
      onPrimary: Colors.white,
      secondary: EchoDeskColors.brandTeal,
      onSecondary: Colors.white,
      tertiary: EchoDeskColors.accent,
      surface: EchoDeskColors.surface,
      onSurface: EchoDeskColors.ink,
      surfaceContainerLowest: EchoDeskColors.background,
      surfaceContainerLow: EchoDeskColors.surface,
      surfaceContainer: EchoDeskColors.surfaceSoft,
      surfaceContainerHigh: EchoDeskColors.surfaceMuted,
      surfaceContainerHighest: EchoDeskColors.surfaceMuted,
      outline: EchoDeskColors.line,
      outlineVariant: EchoDeskColors.lineStrong,
      error: const Color(0xFFB42318),
    );

    final base = ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      scaffoldBackgroundColor: EchoDeskColors.background,
      fontFamily: '.SF Pro Text',
    );

    final textTheme = base.textTheme
        .apply(
          bodyColor: EchoDeskColors.ink,
          displayColor: EchoDeskColors.ink,
          fontFamily: '.SF Pro Text',
        )
        .copyWith(
          displaySmall: base.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
            height: 1.05,
          ),
          headlineMedium: base.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
            height: 1.12,
          ),
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
            height: 1.15,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
          bodyLarge: base.textTheme.bodyLarge?.copyWith(
            height: 1.45,
            color: EchoDeskColors.muted,
            letterSpacing: 0,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            height: 1.45,
            color: EchoDeskColors.muted,
            letterSpacing: 0,
          ),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            height: 1.35,
            color: EchoDeskColors.soft,
            letterSpacing: 0,
          ),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        );

    final roundedRectangle = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
    );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: EchoDeskColors.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: EchoDeskColors.ink,
        titleTextStyle: textTheme.headlineSmall?.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: const IconThemeData(color: EchoDeskColors.ink, size: 28),
      ),
      cardTheme: CardThemeData(
        color: EchoDeskColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EchoDeskRadii.md),
          side: const BorderSide(color: EchoDeskColors.line),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: EchoDeskColors.line,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          backgroundColor: EchoDeskColors.brand,
          foregroundColor: Colors.white,
          disabledBackgroundColor: EchoDeskColors.line,
          disabledForegroundColor: EchoDeskColors.soft,
          shape: roundedRectangle,
          textStyle: textTheme.labelLarge,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          elevation: 0,
          shadowColor: Colors.transparent,
          backgroundColor: EchoDeskColors.brand,
          foregroundColor: Colors.white,
          shape: roundedRectangle,
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          foregroundColor: EchoDeskColors.brand,
          side: const BorderSide(color: EchoDeskColors.lineStrong),
          shape: roundedRectangle,
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: EchoDeskColors.brand,
          textStyle: textTheme.labelLarge,
          shape: roundedRectangle,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: EchoDeskColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
          borderSide: const BorderSide(color: EchoDeskColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
          borderSide: const BorderSide(color: EchoDeskColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
          borderSide: const BorderSide(color: EchoDeskColors.brand, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
          borderSide: BorderSide(color: colorScheme.error),
        ),
        labelStyle: const TextStyle(color: EchoDeskColors.muted),
        hintStyle: const TextStyle(color: EchoDeskColors.soft),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 74,
        elevation: 0,
        backgroundColor: EchoDeskColors.background,
        surfaceTintColor: Colors.transparent,
        indicatorColor: EchoDeskColors.brandSoft,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? EchoDeskColors.brand : EchoDeskColors.soft,
            size: 26,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected ? EchoDeskColors.brand : EchoDeskColors.soft,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          );
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: EchoDeskColors.ink,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
        ),
      ),
    );
  }
}
