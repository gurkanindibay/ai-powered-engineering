package com.sitepulse.backend.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;

public class SaasDtos {

    public record RegisterSiteRequest(
        String siteName,
        String address,
        String city,
        String planType,
        String siteAdminFullName,
        String siteAdminEmail,
        String siteAdminPhone
    ) {}

    public record SiteRegistrationResponse(
        String siteId,
        String siteName,
        String slug,
        String status,
        String planType,
        String siteAdminId,
        String siteAdminFullName,
        String siteAdminEmail,
        String temporaryPassword,
        Boolean mustChangePassword,
        OffsetDateTime createdAt
    ) {}

    public record SaasSiteSummaryDto(
        String siteId,
        String siteName,
        String slug,
        String address,
        String status,
        String planType,
        LocalDate licenseEndDate,
        int totalUnits,
        BigDecimal totalMonthlyDues,
        String siteAdminName,
        String siteAdminEmail,
        String siteAdminPhone
    ) {}

    public record SaasGlobalStatsDto(
        long totalSites,
        long activeSubscriptions,
        int totalManagedUnits,
        BigDecimal totalMonthlyCollectionVolume
    ) {}
}
