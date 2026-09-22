package com.sitepulse.app.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

// Light Theme Tokens (Papara White / Classic)
val LightBackground = Color(0xFFF8F9FA)
val LightSurface = Color(0xFFFFFFFF)
val LightSurfaceBorder = Color(0xFFEBECEF)
val LightSurfaceMuted = Color(0xFFF3F4F6)
val LightTextPrimary = Color(0xFF0F172A)
val LightTextSecondary = Color(0xFF64748B)
val LightTextMuted = Color(0xFF94A3B8)
val LightPrimaryDark = Color(0xFF111827)
val LightButtonPrimaryBg = Color(0xFF111827)
val LightButtonPrimaryText = Color(0xFFFFFFFF)
val LightButtonSecondaryBg = Color(0xFFF3F4F6)
val LightButtonSecondaryText = Color(0xFF0F172A)
val LightNavActive = Color(0xFF111827)
val LightNavInactive = Color(0xFF64748B)
val LightAvatarBg = Color(0xFFE2E8F0)
val LightAvatarBorder = Color(0xFFCBD5E1)

// Dark Theme Tokens (Papara Midnight)
val DarkBackground = Color(0xFF0B0F17)
val DarkSurface = Color(0xFF141A29)
val DarkSurfaceBorder = Color(0xFF222D42)
val DarkSurfaceMuted = Color(0xFF1B2337)
val DarkTextPrimary = Color(0xFFF8FAFC)
val DarkTextSecondary = Color(0xFF94A3B8)
val DarkTextMuted = Color(0xFF64748B)
val DarkPrimaryDark = Color(0xFFFFFFFF)
val DarkButtonPrimaryBg = Color(0xFFF8FAFC)
val DarkButtonPrimaryText = Color(0xFF0B0F17)
val DarkButtonSecondaryBg = Color(0xFF1E283D)
val DarkButtonSecondaryText = Color(0xFFF8FAFC)
val DarkNavActive = Color(0xFF38BDF8)
val DarkNavInactive = Color(0xFF64748B)
val DarkAvatarBg = Color(0xFF1E293B)
val DarkAvatarBorder = Color(0xFF334155)

// Shared Semantic Accents
val AccentRed = Color(0xFFFF3B30)
val AccentRedDark = Color(0xFFFF453A)
val AccentRedBg = Color(0xFFFEE2E2)
val AccentRedBgDark = Color(0x33FF453A)

val SuccessGreen = Color(0xFF10B981)
val SuccessGreenDark = Color(0xFF34D399)
val SuccessGreenBg = Color(0xFFD1FAE5)
val SuccessGreenBgDark = Color(0x3334D399)

val WarningAmber = Color(0xFFF59E0B)
val WarningAmberBg = Color(0xFFFEF3C7)
val WarningAmberBgDark = Color(0x33F59E0B)

// Backward compatibility references
val Background = LightBackground
val Surface = LightSurface
val SurfaceBorder = LightSurfaceBorder
val SurfaceMuted = LightSurfaceMuted
val TextPrimary = LightTextPrimary
val TextSecondary = LightTextSecondary
val TextMuted = LightTextMuted
val PrimaryDark = LightPrimaryDark

@Immutable
data class SitePulseCustomColors(
    val background: Color,
    val surface: Color,
    val surfaceBorder: Color,
    val surfaceMuted: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textMuted: Color,
    val primaryDark: Color,
    val buttonPrimaryBg: Color,
    val buttonPrimaryText: Color,
    val buttonSecondaryBg: Color,
    val buttonSecondaryText: Color,
    val accentRed: Color,
    val accentRedBg: Color,
    val successGreen: Color,
    val successGreenBg: Color,
    val warningAmberBg: Color,
    val navActive: Color,
    val navInactive: Color,
    val avatarBg: Color,
    val avatarBorder: Color,
    val isDark: Boolean
)

val LocalSitePulseColors = staticCompositionLocalOf {
    SitePulseCustomColors(
        background = LightBackground,
        surface = LightSurface,
        surfaceBorder = LightSurfaceBorder,
        surfaceMuted = LightSurfaceMuted,
        textPrimary = LightTextPrimary,
        textSecondary = LightTextSecondary,
        textMuted = LightTextMuted,
        primaryDark = LightPrimaryDark,
        buttonPrimaryBg = LightButtonPrimaryBg,
        buttonPrimaryText = LightButtonPrimaryText,
        buttonSecondaryBg = LightButtonSecondaryBg,
        buttonSecondaryText = LightButtonSecondaryText,
        accentRed = AccentRed,
        accentRedBg = AccentRedBg,
        successGreen = SuccessGreen,
        successGreenBg = SuccessGreenBg,
        warningAmberBg = WarningAmberBg,
        navActive = LightNavActive,
        navInactive = LightNavInactive,
        avatarBg = LightAvatarBg,
        avatarBorder = LightAvatarBorder,
        isDark = false
    )
}
