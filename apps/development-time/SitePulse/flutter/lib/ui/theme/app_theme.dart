import 'package:flutter/material.dart';

/// Colour tokens.
///
/// Two tiers exist for every status colour:
/// * the bright `accent*` tones are for icons, tinted tiles and fills that carry
///   no text;
/// * the `*Fill` tones are for solid surfaces that carry white text (filled
///   buttons, snackbars, badges) and the `*Text(context)` getters are for text
///   drawn in a status colour. Both reach WCAG AA (4.5:1) in light and dark
///   themes; see `test/design_system_test.dart`.
class AppColors {
  // Brand & accents: icons, tinted backgrounds, progress fills (no text on top).
  static const primary = Color(0xFF0284C7);
  static const accentCyan = Color(0xFF0284C7);
  static const accentSky = Color(0xFF38BDF8);
  static const accentGreen = Color(0xFF10B981);
  static const accentRed = Color(0xFFEF4444);
  static const accentOrange = Color(0xFFF59E0B);
  static const accentPurple = Color(0xFF8B5CF6);

  // Solid fills that carry white text (>= 4.5:1 against white).
  static const primaryFill = Color(0xFF0369A1);
  static const successFill = Color(0xFF047857);
  static const warningFill = Color(0xFFB45309);
  static const dangerFill = Color(0xFFB91C1C);
  static const infoFill = Color(0xFF0369A1);
  static const neutralFill = Color(0xFF475569);
  static const purpleFill = Color(0xFF6D28D9);
  static const onFill = Colors.white;

  // Status text on light surfaces (>= 4.5:1 on white and on lightBackground).
  static const primaryTextLight = Color(0xFF0369A1);
  static const successTextLight = Color(0xFF047857);
  static const warningTextLight = Color(0xFFB45309);
  static const dangerTextLight = Color(0xFFB91C1C);

  // Status text on dark surfaces (>= 4.5:1 on darkBackground and darkSurface).
  static const primaryTextDark = Color(0xFF38BDF8);
  static const successTextDark = Color(0xFF34D399);
  static const warningTextDark = Color(0xFFFBBF24);
  static const dangerTextDark = Color(0xFFF87171);

  // Dark theme surfaces
  static const darkBackground = Color(0xFF121317);
  static const darkSurface = Color(0xFF1C1D24);
  static const darkCard = Color(0xFF181920);
  static const darkBorder = Color(0xFF282A33);
  static const darkTextPrimary = Color(0xFFFFFFFF);
  // Raised from 0xFF8E9297 so secondary text reaches 4.5:1 on every dark surface.
  static const darkTextSecondary = Color(0xFF9CA0A6);

  // Light theme surfaces
  static const lightBackground = Color(0xFFF4F7FC);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightCard = Color(0xFFF8FAFD);
  static const lightBorder = Color(0xFFE2E8F0);
  static const lightTextPrimary = Color(0xFF0F172A);
  // Raised from 0xFF64748B so secondary text reaches 4.5:1 on lightBackground.
  static const lightTextSecondary = Color(0xFF526077);

  // Dynamic theme helpers
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

  /// Text drawn in the brand colour.
  static Color primaryText(BuildContext context) =>
      isDark(context) ? primaryTextDark : primaryTextLight;

  static Color successText(BuildContext context) =>
      isDark(context) ? successTextDark : successTextLight;

  static Color warningText(BuildContext context) =>
      isDark(context) ? warningTextDark : warningTextLight;

  static Color dangerText(BuildContext context) =>
      isDark(context) ? dangerTextDark : dangerTextLight;

  static Color purpleText(BuildContext context) =>
      isDark(context) ? const Color(0xFFA78BFA) : purpleFill;

  /// Text-safe version of a bright accent passed around as a widget parameter
  /// (badge colours, status colours). Unknown colours are returned unchanged.
  static Color accentText(BuildContext context, Color accent) {
    if (accent == accentGreen) return successText(context);
    if (accent == accentRed) return dangerText(context);
    if (accent == accentOrange) return warningText(context);
    if (accent == accentCyan || accent == primary) return primaryText(context);
    if (accent == accentPurple) return purpleText(context);
    return accent;
  }
}

/// Spacing, radius and size tokens (GUI component standards, UX report).
class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  static const double screenGutter = 16;
  static const double sectionGap = 24;
}

class AppRadius {
  static const double chip = 8;
  static const double control = 12;
  static const double card = 20;
  static const double sheet = 28;
}

/// Layout breakpoints in logical pixels.
class AppBreakpoints {
  static const double medium = 600;
  static const double expanded = 840;
  static const double maxContentWidth = 1200;

  static bool isExpanded(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= expanded;
}

/// Minimum touch target (Material / WCAG 2.5.5).
const double kMinTouchTarget = 48;

/// Status colour roles exposed through `Theme.of(context).extension<StatusColors>()`.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color successFill;
  final Color warningFill;
  final Color dangerFill;
  final Color infoFill;
  final Color onFill;

  const StatusColors({
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.successFill,
    required this.warningFill,
    required this.dangerFill,
    required this.infoFill,
    required this.onFill,
  });

  static const light = StatusColors(
    success: AppColors.successTextLight,
    warning: AppColors.warningTextLight,
    danger: AppColors.dangerTextLight,
    info: AppColors.primaryTextLight,
    successFill: AppColors.successFill,
    warningFill: AppColors.warningFill,
    dangerFill: AppColors.dangerFill,
    infoFill: AppColors.infoFill,
    onFill: AppColors.onFill,
  );

  static const dark = StatusColors(
    success: AppColors.successTextDark,
    warning: AppColors.warningTextDark,
    danger: AppColors.dangerTextDark,
    info: AppColors.primaryTextDark,
    successFill: AppColors.successFill,
    warningFill: AppColors.warningFill,
    dangerFill: AppColors.dangerFill,
    infoFill: AppColors.infoFill,
    onFill: AppColors.onFill,
  );

  @override
  StatusColors copyWith({
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? successFill,
    Color? warningFill,
    Color? dangerFill,
    Color? infoFill,
    Color? onFill,
  }) {
    return StatusColors(
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      info: info ?? this.info,
      successFill: successFill ?? this.successFill,
      warningFill: warningFill ?? this.warningFill,
      dangerFill: dangerFill ?? this.dangerFill,
      infoFill: infoFill ?? this.infoFill,
      onFill: onFill ?? this.onFill,
    );
  }

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      info: Color.lerp(info, other.info, t)!,
      successFill: Color.lerp(successFill, other.successFill, t)!,
      warningFill: Color.lerp(warningFill, other.warningFill, t)!,
      dangerFill: Color.lerp(dangerFill, other.dangerFill, t)!,
      infoFill: Color.lerp(infoFill, other.infoFill, t)!,
      onFill: Color.lerp(onFill, other.onFill, t)!,
    );
  }
}

class AppTheme {
  /// Type scale: Amount 32/700 · Title 20/600 · Subtitle 16/600 · Body 14/400 · Label 12/500.
  /// 12 px is the floor for any text in the app.
  static TextTheme textTheme(Color primary, Color secondary) {
    return TextTheme(
      displaySmall: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: primary, height: 1.15,
          fontFeatures: const [FontFeature.tabularFigures()]),
      headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: primary),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: primary),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: primary),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: primary),
      bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: primary),
      bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: primary),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: secondary),
      labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: secondary),
      labelSmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: secondary),
    );
  }

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme colorScheme,
    required Color background,
    required Color surface,
    required Color border,
    required Color textPrimary,
    required Color textSecondary,
    required StatusColors status,
  }) {
    final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control));
    const minButtonSize = Size(kMinTouchTarget, kMinTouchTarget);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      textTheme: textTheme(textPrimary, textSecondary),
      extensions: [status],
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: border, width: 1),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primaryFill,
          foregroundColor: AppColors.onFill,
          minimumSize: minButtonSize,
          shape: controlShape,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(minimumSize: minButtonSize, shape: controlShape),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: minButtonSize, shape: controlShape),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: minButtonSize),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
        helperStyle: TextStyle(fontSize: 12, color: textSecondary),
        errorStyle: TextStyle(fontSize: 12, color: status.danger),
        errorMaxLines: 3,
      ),
      snackBarTheme: const SnackBarThemeData(
        contentTextStyle: TextStyle(fontSize: 14, color: AppColors.onFill),
      ),
      tooltipTheme: const TooltipThemeData(textStyle: TextStyle(fontSize: 12, color: Colors.white)),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        selectedLabelTextStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textPrimary),
        unselectedLabelTextStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: textSecondary),
      ),
    );
  }

  static ThemeData dark() {
    return _build(
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primaryTextDark,
        onPrimary: Color(0xFF0B1220),
        secondary: AppColors.successTextDark,
        onSecondary: Color(0xFF0B1220),
        surface: AppColors.darkSurface,
        onSurface: AppColors.darkTextPrimary,
        onSurfaceVariant: AppColors.darkTextSecondary,
        surfaceContainer: AppColors.darkCard,
        outline: AppColors.darkBorder,
        error: AppColors.dangerTextDark,
        onError: Color(0xFF0B1220),
      ),
      background: AppColors.darkBackground,
      surface: AppColors.darkSurface,
      border: AppColors.darkBorder,
      textPrimary: AppColors.darkTextPrimary,
      textSecondary: AppColors.darkTextSecondary,
      status: StatusColors.dark,
    );
  }

  static ThemeData light() {
    return _build(
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: AppColors.primaryFill,
        onPrimary: AppColors.onFill,
        secondary: AppColors.successFill,
        onSecondary: AppColors.onFill,
        surface: AppColors.lightSurface,
        onSurface: AppColors.lightTextPrimary,
        onSurfaceVariant: AppColors.lightTextSecondary,
        surfaceContainer: AppColors.lightCard,
        outline: AppColors.lightBorder,
        error: AppColors.dangerFill,
        onError: AppColors.onFill,
      ),
      background: AppColors.lightBackground,
      surface: AppColors.lightSurface,
      border: AppColors.lightBorder,
      textPrimary: AppColors.lightTextPrimary,
      textSecondary: AppColors.lightTextSecondary,
      status: StatusColors.light,
    );
  }
}
