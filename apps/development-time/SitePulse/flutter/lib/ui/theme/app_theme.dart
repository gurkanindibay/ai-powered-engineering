import 'package:flutter/material.dart';

class AppColors {
  // Brand & Accents (Calm, Non-Neon, Refined Fintech)
  static const primary = Color(0xFF0284C7);
  static const accentCyan = Color(0xFF0284C7);    // Refined Fintech Blue (Replaces neon cyan)
  static const accentSky = Color(0xFF38BDF8);     // Soft Muted Sky
  static const accentGreen = Color(0xFF10B981);   // Natural Emerald Green (Replaces neon green)
  static const accentRed = Color(0xFFEF4444);     // Refined Crimson Red (Replaces neon hot pink)
  static const accentOrange = Color(0xFFF59E0B);  // Warm Natural Amber (Replaces neon orange)

  // Dark Theme (Papara Iconic Black & White / Matte Obsidian)
  static const darkBackground = Color(0xFF121317);
  static const darkSurface = Color(0xFF1C1D24);
  static const darkCard = Color(0xFF181920);
  static const darkBorder = Color(0xFF282A33);
  static const darkTextPrimary = Color(0xFFFFFFFF);
  static const darkTextSecondary = Color(0xFF8E9297);

  // Light Theme
  static const lightBackground = Color(0xFFF4F7FC);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightCard = Color(0xFFF8FAFD);
  static const lightBorder = Color(0xFFE2E8F0);
  static const lightTextPrimary = Color(0xFF0F172A);
  static const lightTextSecondary = Color(0xFF64748B);

  // Dynamic Theme Helpers
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color surface(BuildContext context) =>
      isDark(context) ? darkSurface : lightSurface;

  static Color background(BuildContext context) =>
      isDark(context) ? darkBackground : lightBackground;

  static Color card(BuildContext context) =>
      isDark(context) ? darkCard : lightCard;

  static Color border(BuildContext context) =>
      isDark(context) ? darkBorder : lightBorder;

  static Color textPrimary(BuildContext context) =>
      isDark(context) ? darkTextPrimary : lightTextPrimary;

  static Color textSecondary(BuildContext context) =>
      isDark(context) ? darkTextSecondary : lightTextSecondary;
}

class AppTheme {
  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.darkBackground,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accentCyan,
        secondary: AppColors.accentGreen,
        surface: AppColors.darkSurface,
        error: AppColors.accentRed,
      ),
      cardTheme: CardThemeData(
        color: AppColors.darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.darkBorder, width: 1),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.darkBackground,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
    );
  }

  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.lightBackground,
      colorScheme: const ColorScheme.light(
        primary: AppColors.primary,
        secondary: AppColors.accentGreen,
        surface: AppColors.lightSurface,
        error: AppColors.accentRed,
      ),
      cardTheme: CardThemeData(
        color: AppColors.lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.lightBorder, width: 1),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.lightBackground,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
    );
  }
}
