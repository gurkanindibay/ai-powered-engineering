import 'package:flutter/material.dart';

class AppColors {
  // Brand & Accents
  static const primary = Color(0xFF00629E);
  static const accentCyan = Color(0xFF00D2FF);
  static const accentGreen = Color(0xFF00E5A3);
  static const accentRed = Color(0xFFFF4B72);
  static const accentOrange = Color(0xFFFF9500);

  // Dark Theme (Papara Midnight)
  static const darkBackground = Color(0xFF0B0F19);
  static const darkSurface = Color(0xFF151D2F);
  static const darkCard = Color(0xFF1B2438);
  static const darkBorder = Color(0xFF26324D);
  static const darkTextPrimary = Color(0xFFF8FAFC);
  static const darkTextSecondary = Color(0xFF94A3B8);

  // Light Theme
  static const lightBackground = Color(0xFFF4F7FC);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightCard = Color(0xFFF8FAFD);
  static const lightBorder = Color(0xFFE2E8F0);
  static const lightTextPrimary = Color(0xFF0F172A);
  static const lightTextSecondary = Color(0xFF64748B);
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
