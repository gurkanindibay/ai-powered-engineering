package com.sitepulse.backend.dto;

import com.sitepulse.backend.domain.model.Permission;
import com.sitepulse.backend.domain.model.Role;

import java.util.List;
import java.util.Set;

public class AuthDtos {

    public record PasswordLoginRequest(
        String email,
        String password
    ) {}

    public record GoogleLoginRequest(
        String idToken,
        String inviteToken,
        String unitInviteToken
    ) {}

    public record RegisterUserRequest(
        String fullName,
        String email,
        String phone,
        String password,
        String inviteToken,
        String unitInviteToken
    ) {}

    public record UserSummary(
        String id,
        String fullName,
        String email,
        String phone,
        Role role,
        String siteId,
        String unitId,
        String avatarUrl,
        String authProvider,
        boolean mustChangePassword,
        Set<Permission> permissions
    ) {}

    public record AuthResponse(
        String accessToken,
        String tokenType,
        long expiresInSeconds,
        UserSummary user
    ) {}

    public record UserProfileResponse(
        String id,
        String fullName,
        String email,
        String phone,
        Role role,
        String siteId,
        String unitId,
        String avatarUrl,
        String authProvider,
        boolean mustChangePassword,
        Set<Permission> permissions,
        List<String> permissionDescriptions
    ) {}
}
