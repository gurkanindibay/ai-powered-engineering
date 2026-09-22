package com.sitepulse.backend.dto;

import java.time.Instant;

public class UnitInvitationDtos {

    public record GenerateUnitInviteRequest(
            String unitId,
            String relationship // e.g. "FAMILY_MEMBER", "SPOUSE", "TENANT", "CO_RESIDENT"
    ) {}

    public record UnitInviteLinkResponse(
            String inviteUrl,
            String token,
            String unitId,
            String building,
            String unitNumber,
            String relationship,
            Instant expiresAt,
            String securityScopeNotice
    ) {}

    public record RegisterHomeResidentRequest(
            String token,
            String fullName,
            String email,
            String phone,
            String relationship
    ) {}

    public record HomeResidentResponse(
            String residentId,
            String fullName,
            String email,
            String phone,
            String unitId,
            String role, // "HOME_RESIDENT"
            String temporaryPassword,
            String permissionScope, // "UNIT_ONLY"
            Instant registeredAt
    ) {}

    public record UnitMemberDto(
            String id,
            String fullName,
            String relationship,
            String phone,
            String email,
            boolean isOwner
    ) {}
}
