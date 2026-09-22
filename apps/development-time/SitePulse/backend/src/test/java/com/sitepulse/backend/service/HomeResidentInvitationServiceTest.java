package com.sitepulse.backend.service;

import com.sitepulse.backend.domain.entity.BagimsizBolumEntity;
import com.sitepulse.backend.dto.UnitInvitationDtos.*;
import com.sitepulse.backend.repository.BagimsizBolumRepository;
import com.sitepulse.backend.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

public class HomeResidentInvitationServiceTest {

    private BagimsizBolumRepository bagimsizBolumRepository;
    private UserRepository userRepository;
    private HomeResidentInvitationService service;

    @BeforeEach
    void setUp() {
        bagimsizBolumRepository = Mockito.mock(BagimsizBolumRepository.class);
        userRepository = Mockito.mock(UserRepository.class);

        BagimsizBolumEntity unit = new BagimsizBolumEntity(
                "d-14",
                "A Blok",
                14,
                4,
                100,
                "usr-ahmet",
                null
        );
        when(bagimsizBolumRepository.findById("d-14")).thenReturn(Optional.of(unit));
        when(userRepository.existsByEposta("existing@begonya.com")).thenReturn(true);
        when(userRepository.existsByEposta("zeynep.yilmaz@gmail.com")).thenReturn(false);

        service = new HomeResidentInvitationService(bagimsizBolumRepository, userRepository);
    }

    @Test
    void whenGeneratingUnitInviteLink_thenReturnsUnitScopedUrlAndToken() {
        UnitInviteLinkResponse response = service.generateUnitInviteLink("d-14", "Eş / Sakin");

        assertNotNull(response);
        assertEquals("d-14", response.unitId());
        assertEquals("A Blok", response.building());
        assertEquals("14", response.unitNumber());
        assertTrue(response.token().startsWith("SP-HANE-"));
        assertTrue(response.inviteUrl().contains("/join/begonya-sitesi/units/d-14?token="));
        assertTrue(response.securityScopeNotice().contains("A Blok D:14 yetkisi tanımlar"));
        assertNotNull(response.expiresAt());
    }

    @Test
    void whenRegisteringHomeResident_thenAssignsHomeResidentRoleAndUnitScope() {
        // Step 1: Generate invite
        UnitInviteLinkResponse link = service.generateUnitInviteLink("d-14", "Eş");

        // Step 2: Register co-resident
        RegisterHomeResidentRequest request = new RegisterHomeResidentRequest(
                link.token(),
                "Zeynep Yılmaz",
                "zeynep.yilmaz@gmail.com",
                "+90 532 999 88 77",
                "Eş / Sakin"
        );

        HomeResidentResponse response = service.registerHomeResident(request);

        assertNotNull(response);
        assertEquals("Zeynep Yılmaz", response.fullName());
        assertEquals("zeynep.yilmaz@gmail.com", response.email());
        assertEquals("d-14", response.unitId());
        assertEquals("HOME_RESIDENT", response.role());
        assertTrue(response.temporaryPassword().startsWith("SP-HANE-"));
        assertTrue(response.permissionScope().contains("d-14"));

        // Step 3: Verify household member list includes Zeynep
        List<UnitMemberDto> members = service.getUnitMembers("d-14");
        assertTrue(members.stream().anyMatch(m -> m.fullName().equals("Zeynep Yılmaz")));
    }

    @Test
    void whenDuplicateEmailForHomeResident_thenThrowsException() {
        UnitInviteLinkResponse link = service.generateUnitInviteLink("d-14", "Aile Üyesi");

        RegisterHomeResidentRequest request = new RegisterHomeResidentRequest(
                link.token(),
                "Duplicate User",
                "existing@begonya.com",
                "+90 555 444 33 22",
                "Aile Üyesi"
        );

        assertThrows(IllegalArgumentException.class, () -> service.registerHomeResident(request));
    }
}
