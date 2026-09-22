package com.sitepulse.backend.domain.model;

import java.util.*;

/**
 * Authority and scope enforcement matrix mapping Roles to fine-grained action Permissions.
 */
public final class RolePermissions {

    private static final Map<Role, Set<Permission>> MATRIX = new EnumMap<>(Role.class);

    static {
        // 1. SAAS_ADMIN: Cross-tenant governance & site creation
        MATRIX.put(Role.SAAS_ADMIN, EnumSet.of(
            Permission.TENANT_MANAGE,
            Permission.SITE_MANAGE,
            Permission.ANNOUNCEMENT_BROADCAST,
            Permission.UNIT_READ
        ));

        // 2. SITE_MANAGER: Full operations within a specific site complex
        MATRIX.put(Role.SITE_MANAGER, EnumSet.of(
            Permission.SITE_MANAGE,
            Permission.RESIDENT_INVITE_SITE,
            Permission.RESIDENT_APPROVE,
            Permission.LEDGER_MANAGE_ALL,
            Permission.ANNOUNCEMENT_BROADCAST,
            Permission.UNIT_READ
        ));

        // 3. HOME_OWNER (Kat Maliki): Full flat-level management + co-resident invitations
        MATRIX.put(Role.HOME_OWNER, EnumSet.of(
            Permission.UNIT_READ,
            Permission.UNIT_PAY,
            Permission.UNIT_TICKET_SUBMIT,
            Permission.UNIT_INVITE_CO_RESIDENT,
            Permission.UNIT_MANAGE_HOUSEHOLD
        ));

        // 4. HOME_RESIDENT (Ev Sakini / Kiracı / Aile): Flat-level viewing & payments, no invite authority
        MATRIX.put(Role.HOME_RESIDENT, EnumSet.of(
            Permission.UNIT_READ,
            Permission.UNIT_PAY,
            Permission.UNIT_TICKET_SUBMIT
        ));
    }

    private RolePermissions() {}

    public static Set<Permission> getPermissionsForRole(Role role) {
        if (role == null) return Collections.emptySet();
        return Collections.unmodifiableSet(MATRIX.getOrDefault(role, Collections.emptySet()));
    }

    public static boolean hasPermission(Role role, Permission permission) {
        if (role == null || permission == null) return false;
        Set<Permission> perms = MATRIX.get(role);
        return perms != null && perms.contains(permission);
    }
}
