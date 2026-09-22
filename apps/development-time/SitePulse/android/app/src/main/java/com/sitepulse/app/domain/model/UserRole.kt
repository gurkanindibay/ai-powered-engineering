package com.sitepulse.app.domain.model

enum class UserRole(val displayName: String, val badgeColorHex: Long) {
    SAAS_ADMIN("SaaS Platform Admin", 0xFF6200EE),
    SITE_MANAGER("Site Yöneticisi", 0xFF0D47A1),
    HOME_OWNER("Kat Maliki (Ev Sahibi)", 0xFF00695C),
    HOME_RESIDENT("Ev Sakini (Aile / Kiracı)", 0xFF2E7D32),
    RESIDENT("Kat Maliki (Ev Sahibi)", 0xFF00695C) // Backward compatibility alias
}

