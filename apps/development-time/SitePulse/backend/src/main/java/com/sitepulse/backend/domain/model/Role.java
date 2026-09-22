package com.sitepulse.backend.domain.model;

/**
 * Enterprise Roles within the SitePulse multi-tenant residential platform.
 */
public enum Role {
    SAAS_ADMIN("Platform Super Admin", "Cross-tenant global platform operations"),
    SITE_MANAGER("Site / Complex Manager", "Full complex management for a specific site"),
    HOME_OWNER("Kat Maliki (Flat Owner)", "Owner of a specific independent unit with co-resident invite capability"),
    HOME_RESIDENT("Ev Sakini (Co-Resident / Family)", "Household resident scoped strictly to their flat without invite authority");

    private final String title;
    private final String description;

    Role(String title, String description) {
        this.title = title;
        this.description = description;
    }

    public String getTitle() { return title; }
    public String getDescription() { return description; }

    public static Role fromString(String roleStr) {
        if (roleStr == null) return HOME_RESIDENT;
        try {
            return Role.valueOf(roleStr.toUpperCase().trim());
        } catch (IllegalArgumentException e) {
            // Backward compatibility
            if ("RESIDENT".equalsIgnoreCase(roleStr)) return HOME_OWNER;
            return HOME_RESIDENT;
        }
    }
}
