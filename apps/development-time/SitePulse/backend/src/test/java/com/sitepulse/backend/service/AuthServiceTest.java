package com.sitepulse.backend.service;

import com.sitepulse.backend.domain.entity.UserEntity;
import com.sitepulse.backend.domain.model.Permission;
import com.sitepulse.backend.domain.model.Role;
import com.sitepulse.backend.domain.model.RolePermissions;
import com.sitepulse.backend.dto.AuthDtos.*;
import com.sitepulse.backend.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

public class AuthServiceTest {

    private UserRepository userRepository;
    private AuthService authService;

    @BeforeEach
    void setUp() {
        userRepository = Mockito.mock(UserRepository.class);
        authService = new AuthService(userRepository);
    }

    @Test
    void whenValidPasswordRegistration_thenCanAuthenticate() {
        when(userRepository.existsByEposta("ahmet.yilmaz@gmail.com")).thenReturn(false);
        String pass = "GucluSifre2026!";
        String passHash = authService.hashPassword(pass);

        UserEntity user = new UserEntity(
            "usr-1", "site-1", "Ahmet Yılmaz", "ahmet.yilmaz@gmail.com",
            "0532 111 22 33", passHash, "HOME_OWNER", false
        );
        when(userRepository.save(any(UserEntity.class))).thenReturn(user);
        when(userRepository.findByEposta("ahmet.yilmaz@gmail.com")).thenReturn(Optional.of(user));

        RegisterUserRequest regReq = new RegisterUserRequest(
            "Ahmet Yılmaz", "ahmet.yilmaz@gmail.com", "0532 111 22 33",
            pass, null, null
        );
        AuthResponse regRes = authService.registerWithPassword(regReq);

        assertNotNull(regRes);
        assertEquals("ahmet.yilmaz@gmail.com", regRes.user().email());
        assertEquals(Role.HOME_OWNER, regRes.user().role());
        assertEquals("LOCAL", regRes.user().authProvider());

        // Authenticate with the password
        PasswordLoginRequest loginReq = new PasswordLoginRequest("ahmet.yilmaz@gmail.com", pass);
        AuthResponse loginRes = authService.authenticateWithPassword(loginReq);

        assertNotNull(loginRes);
        assertNotNull(loginRes.accessToken());
        assertEquals("Bearer", loginRes.tokenType());
        assertTrue(loginRes.user().permissions().contains(Permission.UNIT_PAY));
    }

    @Test
    void whenWrongPassword_thenThrowsException() {
        String passHash = authService.hashPassword("DogruSifre123!");
        UserEntity user = new UserEntity(
            "usr-1", "site-1", "Ahmet Yılmaz", "ahmet@gmail.com",
            "0532 111 22 33", passHash, "HOME_OWNER", false
        );
        when(userRepository.findByEposta("ahmet@gmail.com")).thenReturn(Optional.of(user));

        PasswordLoginRequest loginReq = new PasswordLoginRequest("ahmet@gmail.com", "YanlisSifre!");
        assertThrows(IllegalArgumentException.class, () -> authService.authenticateWithPassword(loginReq));
    }

    @Test
    void whenValidGoogleIdToken_thenAuthenticatesAndLinksAccount() {
        UserEntity existing = new UserEntity(
            "usr-google-1", "site-1", "Zeynep Yılmaz", "zeynep.yilmaz@gmail.com",
            "0532 999 88 77", null, "HOME_RESIDENT", false
        );
        when(userRepository.findByGoogleSub("sub-12345")).thenReturn(Optional.empty());
        when(userRepository.findByEposta("zeynep.yilmaz@gmail.com")).thenReturn(Optional.of(existing));
        when(userRepository.save(any(UserEntity.class))).thenReturn(existing);

        String mockGoogleToken = "mock-google-token:sub-12345:zeynep.yilmaz@gmail.com:Zeynep Yılmaz";
        GoogleLoginRequest googleReq = new GoogleLoginRequest(mockGoogleToken, null, "unit-14");
        AuthResponse response = authService.authenticateWithGoogle(googleReq);

        assertNotNull(response);
        assertEquals("zeynep.yilmaz@gmail.com", response.user().email());
        assertEquals("sub-12345", existing.getGoogleSub());
        assertNotNull(response.accessToken());
    }

    @Test
    void whenResidentRole_thenHasUnitRestrictedPermissions() {
        Role residentRole = Role.HOME_RESIDENT;
        var perms = RolePermissions.getPermissionsForRole(residentRole);

        assertTrue(perms.contains(Permission.UNIT_READ));
        assertTrue(perms.contains(Permission.UNIT_PAY));
        assertTrue(perms.contains(Permission.UNIT_TICKET_SUBMIT));

        // Isolated from management and invite capabilities
        assertFalse(perms.contains(Permission.UNIT_INVITE_CO_RESIDENT));
        assertFalse(perms.contains(Permission.UNIT_MANAGE_HOUSEHOLD));
        assertFalse(perms.contains(Permission.LEDGER_MANAGE_ALL));
        assertFalse(perms.contains(Permission.RESIDENT_APPROVE));
    }

    @Test
    void whenHomeOwnerRole_thenHasInviteAndHouseholdPermissions() {
        Role ownerRole = Role.HOME_OWNER;
        var perms = RolePermissions.getPermissionsForRole(ownerRole);

        assertTrue(perms.contains(Permission.UNIT_READ));
        assertTrue(perms.contains(Permission.UNIT_PAY));
        assertTrue(perms.contains(Permission.UNIT_TICKET_SUBMIT));
        assertTrue(perms.contains(Permission.UNIT_INVITE_CO_RESIDENT));
        assertTrue(perms.contains(Permission.UNIT_MANAGE_HOUSEHOLD));

        // But cannot manage other units or site finances
        assertFalse(perms.contains(Permission.LEDGER_MANAGE_ALL));
        assertFalse(perms.contains(Permission.RESIDENT_APPROVE));
    }
}
