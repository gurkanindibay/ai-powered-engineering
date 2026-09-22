package com.sitepulse.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable

@Composable
fun SitePulseTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val customColors = if (darkTheme) {
        SitePulseCustomColors(
            background = DarkBackground,
            surface = DarkSurface,
            surfaceBorder = DarkSurfaceBorder,
            surfaceMuted = DarkSurfaceMuted,
            textPrimary = DarkTextPrimary,
            textSecondary = DarkTextSecondary,
            textMuted = DarkTextMuted,
            primaryDark = DarkPrimaryDark,
            buttonPrimaryBg = DarkButtonPrimaryBg,
            buttonPrimaryText = DarkButtonPrimaryText,
            buttonSecondaryBg = DarkButtonSecondaryBg,
            buttonSecondaryText = DarkButtonSecondaryText,
            accentRed = AccentRedDark,
            accentRedBg = AccentRedBgDark,
            successGreen = SuccessGreenDark,
            successGreenBg = SuccessGreenBgDark,
            warningAmberBg = WarningAmberBgDark,
            navActive = DarkNavActive,
            navInactive = DarkNavInactive,
            avatarBg = DarkAvatarBg,
            avatarBorder = DarkAvatarBorder,
            isDark = true
        )
    } else {
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

    val materialColors = if (darkTheme) {
        darkColorScheme(
            primary = DarkPrimaryDark,
            background = DarkBackground,
            surface = DarkSurface,
            onSurface = DarkTextPrimary
        )
    } else {
        lightColorScheme(
            primary = LightPrimaryDark,
            background = LightBackground,
            surface = LightSurface,
            onSurface = LightTextPrimary
        )
    }

    CompositionLocalProvider(LocalSitePulseColors provides customColors) {
        MaterialTheme(
            colorScheme = materialColors,
            typography = Typography,
            content = content
        )
    }
}

object SitePulseTheme {
    val colors: SitePulseCustomColors
        @Composable
        @ReadOnlyComposable
        get() = LocalSitePulseColors.current
}
