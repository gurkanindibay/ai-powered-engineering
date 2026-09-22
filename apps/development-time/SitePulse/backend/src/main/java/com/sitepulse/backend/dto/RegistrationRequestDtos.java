package com.sitepulse.backend.dto;

import java.time.OffsetDateTime;

public class RegistrationRequestDtos {

    public record SiteInvitationLinkResponse(
        String siteId,
        String siteName,
        String slug,
        String invitationToken,
        String joinUrl,
        OffsetDateTime expiresAt
    ) {}

    public record SubmitSelfRegistrationRequest(
        String invitationToken,
        String block,
        int unitNo,
        int floor,
        String fullName,
        String email,
        String phone,
        boolean isResident
    ) {}

    public record PendingRegistrationResponse(
        String requestId,
        String siteId,
        String block,
        int unitNo,
        int floor,
        String fullName,
        String email,
        String phone,
        boolean isResident,
        String status, // "PENDING", "APPROVED", "REJECTED"
        OffsetDateTime submittedAt
    ) {}

    public record ApprovalResultResponse(
        String requestId,
        String siteId,
        String status,
        String unitId,
        String residentEmail,
        String temporaryPassword,
        OffsetDateTime approvedAt
    ) {}
}
