package com.sitepulse.backend.domain.model;

/**
 * Granular action permissions within SitePulse.
 */
public enum Permission {
    TENANT_MANAGE("Create/suspend sites, manage SaaS subscriptions"),
    SITE_MANAGE("Update building blocks, site settings, staff"),
    RESIDENT_INVITE_SITE("Generate site-wide resident onboarding links"),
    RESIDENT_APPROVE("Review and approve pending self-registrations"),
    LEDGER_MANAGE_ALL("Manage dues tariffs, expense audits, debt ledger"),
    ANNOUNCEMENT_BROADCAST("Send complex-wide emergency notices & announcements"),
    UNIT_READ("View flat dues, payment receipts, announcements for assigned unit"),
    UNIT_PAY("Execute credit card / bank transfer payment for assigned unit"),
    UNIT_TICKET_SUBMIT("Submit maintenance & repair tickets for assigned unit"),
    UNIT_INVITE_CO_RESIDENT("Generate flat-scoped invitation links for family & co-residents"),
    UNIT_MANAGE_HOUSEHOLD("Add, view, or remove co-residents within the flat");

    private final String description;

    Permission(String description) {
        this.description = description;
    }

    public String getDescription() { return description; }
}
