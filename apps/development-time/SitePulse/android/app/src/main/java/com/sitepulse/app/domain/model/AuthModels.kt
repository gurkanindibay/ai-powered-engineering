package com.sitepulse.app.domain.model

enum class AuthProvider(val label: String, val iconLabel: String) {
    LOCAL("Şifre ile Giriş", "🔑"),
    GOOGLE("Google Hesabı", "🌐"),
    HYBRID("Şifre & Google", "⚡")
}

data class PermissionScope(
    val code: String,
    val title: String,
    val isGranted: Boolean,
    val isolationNote: String
)

data class UserSession(
    val id: String,
    val fullName: String,
    val email: String,
    val phone: String,
    val role: UserRole,
    val siteName: String,
    val unitName: String,
    val authProvider: AuthProvider,
    val avatarUrl: String? = null,
    val permissions: List<PermissionScope>
)
