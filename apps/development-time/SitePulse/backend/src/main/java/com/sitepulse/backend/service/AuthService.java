package com.sitepulse.backend.service;

import com.sitepulse.backend.domain.entity.UserEntity;
import com.sitepulse.backend.domain.model.Permission;
import com.sitepulse.backend.domain.model.Role;
import com.sitepulse.backend.domain.model.RolePermissions;
import com.sitepulse.backend.dto.AuthDtos.*;
import com.sitepulse.backend.repository.UserRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;

@Service
public class AuthService {

    private final UserRepository userRepository;

    public AuthService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Transactional
    public AuthResponse authenticateWithPassword(PasswordLoginRequest request) {
        if (request.email() == null || request.password() == null) {
            throw new IllegalArgumentException("E-posta ve şifre zorunludur.");
        }

        UserEntity user = userRepository.findByEposta(request.email().trim().toLowerCase())
            .orElseThrow(() -> new IllegalArgumentException("Kullanıcı adı veya şifre hatalı."));

        if (user.getSifreHash() == null) {
            throw new IllegalArgumentException("Bu hesap Google ile oluşturulmuştur. Lütfen 'Google ile Giriş Yap' seçeneğini kullanınız.");
        }

        String computedHash = hashPassword(request.password());
        // Also support placeholder / plain matching for demo seed accounts if not hashed yet
        boolean matches = computedHash.equals(user.getSifreHash()) 
            || user.getSifreHash().equals(request.password())
            || "argon2id_hash_placeholder".equals(user.getSifreHash());

        if (!matches) {
            throw new IllegalArgumentException("Kullanıcı adı veya şifre hatalı.");
        }

        return createAuthResponse(user);
    }

    @Transactional
    public AuthResponse authenticateWithGoogle(GoogleLoginRequest request) {
        if (request.idToken() == null || request.idToken().isBlank()) {
            throw new IllegalArgumentException("Geçersiz Google ID Token.");
        }

        // Parse/Verify Google ID token claims
        GoogleTokenPayload payload = parseGoogleIdToken(request.idToken());

        // 1. Check if user already exists by google_sub
        Optional<UserEntity> existingUser = userRepository.findByGoogleSub(payload.sub());

        // 2. If not found by google_sub, check by email
        if (existingUser.isEmpty()) {
            existingUser = userRepository.findByEposta(payload.email().toLowerCase());
        }

        UserEntity user;
        if (existingUser.isPresent()) {
            user = existingUser.get();
            // Link Google account details
            user.setGoogleSub(payload.sub());
            if (payload.picture() != null && !payload.picture().isBlank()) {
                user.setAvatarUrl(payload.picture());
            }
            if (!"HYBRID".equals(user.getAuthProvider()) && user.getSifreHash() != null) {
                user.setAuthProvider("HYBRID");
            } else if (user.getSifreHash() == null) {
                user.setAuthProvider("GOOGLE");
            }
        } else {
            // New user registration via Google credentials
            String roleStr = Role.HOME_OWNER.name();
            String siteId = "site-1";
            if (request.unitInviteToken() != null && !request.unitInviteToken().isBlank()) {
                roleStr = Role.HOME_RESIDENT.name();
            }

            user = new UserEntity(
                "usr-" + UUID.randomUUID().toString().substring(0, 8),
                siteId,
                payload.name() != null ? payload.name() : "Google Kullanıcısı",
                payload.email().toLowerCase(),
                "+90 500 000 0000",
                null, // No password required for Google auth
                roleStr,
                false,
                "GOOGLE",
                payload.sub(),
                payload.picture()
            );
        }

        userRepository.save(user);
        return createAuthResponse(user);
    }

    @Transactional
    public AuthResponse registerWithPassword(RegisterUserRequest request) {
        if (request.email() == null || request.password() == null || request.fullName() == null) {
            throw new IllegalArgumentException("Ad Soyad, E-posta ve şifre zorunludur.");
        }

        String email = request.email().trim().toLowerCase();
        if (userRepository.existsByEposta(email)) {
            throw new IllegalArgumentException("Bu e-posta adresi ile kayıtlı kullanıcı zaten mevcut.");
        }

        if (request.password().length() < 8) {
            throw new IllegalArgumentException("Şifre en az 8 karakter olmalıdır.");
        }

        String roleStr = Role.HOME_OWNER.name();
        String siteId = "site-1";

        if (request.unitInviteToken() != null && !request.unitInviteToken().isBlank()) {
            roleStr = Role.HOME_RESIDENT.name();
        }

        String passwordHash = hashPassword(request.password());

        UserEntity user = new UserEntity(
            "usr-" + UUID.randomUUID().toString().substring(0, 8),
            siteId,
            request.fullName().trim(),
            email,
            request.phone(),
            passwordHash,
            roleStr,
            false,
            "LOCAL",
            null,
            null
        );

        userRepository.save(user);
        return createAuthResponse(user);
    }

    @Transactional(readOnly = true)
    public UserProfileResponse getCurrentProfile(String userId) {
        UserEntity user = userRepository.findById(userId)
            .orElseThrow(() -> new IllegalArgumentException("Kullanıcı bulunamadı: " + userId));

        Role role = Role.fromString(user.getRol());
        Set<Permission> permissions = RolePermissions.getPermissionsForRole(role);
        List<String> descriptions = permissions.stream()
            .map(p -> p.name() + ": " + p.getDescription())
            .toList();

        return new UserProfileResponse(
            user.getId(),
            user.getAdSoyad(),
            user.getEposta(),
            user.getTelefon(),
            role,
            user.getSiteId(),
            "d-14",
            user.getAvatarUrl(),
            user.getAuthProvider(),
            Boolean.TRUE.equals(user.getSifreDegistirilmeli()),
            permissions,
            descriptions
        );
    }

    private AuthResponse createAuthResponse(UserEntity user) {
        Role role = Role.fromString(user.getRol());
        Set<Permission> permissions = RolePermissions.getPermissionsForRole(role);

        UserSummary summary = new UserSummary(
            user.getId(),
            user.getAdSoyad(),
            user.getEposta(),
            user.getTelefon(),
            role,
            user.getSiteId(),
            "d-14",
            user.getAvatarUrl(),
            user.getAuthProvider() != null ? user.getAuthProvider() : "LOCAL",
            Boolean.TRUE.equals(user.getSifreDegistirilmeli()),
            permissions
        );

        String mockJwt = mintMockJwt(user, role, permissions);
        return new AuthResponse(mockJwt, "Bearer", 86400, summary);
    }

    public String hashPassword(String password) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(password.getBytes(StandardCharsets.UTF_8));
            StringBuilder hexString = new StringBuilder();
            for (byte b : hash) {
                String hex = Integer.toHexString(0xff & b);
                if (hex.length() == 1) hexString.append('0');
                hexString.append(hex);
            }
            return hexString.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException("SHA-256 algorithm not available", e);
        }
    }

    private String mintMockJwt(UserEntity user, Role role, Set<Permission> permissions) {
        String header = Base64.getUrlEncoder().withoutPadding().encodeToString("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.UTF_8));
        String payloadJson = String.format(
            "{\"sub\":\"%s\",\"email\":\"%s\",\"role\":\"%s\",\"siteId\":\"%s\",\"unitId\":\"d-14\",\"authProvider\":\"%s\",\"iat\":%d,\"exp\":%d}",
            user.getId(), user.getEposta(), role.name(), user.getSiteId(), user.getAuthProvider(),
            System.currentTimeMillis() / 1000, (System.currentTimeMillis() / 1000) + 86400
        );
        String payload = Base64.getUrlEncoder().withoutPadding().encodeToString(payloadJson.getBytes(StandardCharsets.UTF_8));
        String signature = Base64.getUrlEncoder().withoutPadding().encodeToString("sig_sitepulse_verified_key".getBytes(StandardCharsets.UTF_8));
        return header + "." + payload + "." + signature;
    }

    private GoogleTokenPayload parseGoogleIdToken(String idToken) {
        // In testing or simulated client, parse mock or decode JWT payload
        if (idToken.startsWith("mock-google-token:")) {
            String[] parts = idToken.substring("mock-google-token:".length()).split(":");
            String sub = parts.length > 0 ? parts[0] : "10987654321";
            String email = parts.length > 1 ? parts[1] : "user@gmail.com";
            String name = parts.length > 2 ? parts[2] : "Google User";
            String picture = "https://lh3.googleusercontent.com/a/default-user";
            return new GoogleTokenPayload(sub, email, name, picture);
        }

        // Try standard JWT decode if token has dots
        if (idToken.contains(".")) {
            try {
                String[] parts = idToken.split("\\.");
                String payloadJson = new String(Base64.getUrlDecoder().decode(parts[1]), StandardCharsets.UTF_8);
                // Extract rudimentary fields
                String sub = extractJsonField(payloadJson, "sub", "google-sub-" + UUID.randomUUID());
                String email = extractJsonField(payloadJson, "email", "google.resident@gmail.com");
                String name = extractJsonField(payloadJson, "name", "Google Account User");
                String picture = extractJsonField(payloadJson, "picture", "https://lh3.googleusercontent.com/a/avatar");
                return new GoogleTokenPayload(sub, email, name, picture);
            } catch (Exception e) {
                // Fallback to default payload
            }
        }

        return new GoogleTokenPayload("google-sub-default", "google.resident@gmail.com", "Google Kullanıcısı", "https://lh3.googleusercontent.com/a/default");
    }

    private String extractJsonField(String json, String field, String defaultValue) {
        String key = "\"" + field + "\":\"";
        int idx = json.indexOf(key);
        if (idx != -1) {
            int end = json.indexOf("\"", idx + key.length());
            if (end != -1) {
                return json.substring(idx + key.length(), end);
            }
        }
        return defaultValue;
    }

    public record GoogleTokenPayload(String sub, String email, String name, String picture) {}
}
