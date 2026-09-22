package com.sitepulse.backend.service;

import com.sitepulse.backend.domain.entity.SiteEntity;
import com.sitepulse.backend.domain.entity.UserEntity;
import com.sitepulse.backend.dto.RegistrationRequestDtos.*;
import com.sitepulse.backend.repository.SiteRepository;
import com.sitepulse.backend.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

public class RegistrationApprovalServiceTest {

    private SiteRepository siteRepository;
    private UserRepository userRepository;
    private RegistrationApprovalService service;

    @BeforeEach
    void setUp() {
        siteRepository = Mockito.mock(SiteRepository.class);
        userRepository = Mockito.mock(UserRepository.class);

        SiteEntity site = new SiteEntity(
            "site-1",
            "Begonya Sitesi",
            "Ataşehir",
            "begonya-sitesi",
            "ACTIVE",
            "PREMIUM",
            null
        );
        when(siteRepository.findById("site-1")).thenReturn(Optional.of(site));
        when(siteRepository.findBySlug("begonya-sitesi")).thenReturn(Optional.of(site));

        service = new RegistrationApprovalService(siteRepository, userRepository);
    }

    @Test
    void whenGeneratingInviteLink_thenReturnsValidUrlAndToken() {
        SiteInvitationLinkResponse response = service.generateInvitationLink("site-1");

        assertNotNull(response);
        assertEquals("site-1", response.siteId());
        assertEquals("begonya-sitesi", response.slug());
        assertTrue(response.invitationToken().startsWith("SP-INV-"));
        assertTrue(response.joinUrl().contains("/join/begonya-sitesi?token="));
        assertNotNull(response.expiresAt());
    }

    @Test
    void whenSubmittingSelfRegistration_thenCreatesPendingRequest() {
        SubmitSelfRegistrationRequest request = new SubmitSelfRegistrationRequest(
            "SP-INV-XYZ123",
            "B Blok",
            22,
            5,
            "Barış Manço",
            "baris@manco.com",
            "+90 532 000 0000",
            true
        );

        when(userRepository.existsByEposta("baris@manco.com")).thenReturn(false);

        PendingRegistrationResponse response = service.submitSelfRegistration("begonya-sitesi", request);

        assertNotNull(response);
        assertEquals("PENDING", response.status());
        assertEquals("Barış Manço", response.fullName());
        assertEquals("baris@manco.com", response.email());
        assertEquals(22, response.unitNo());
    }

    @Test
    void whenApprovingPendingRegistration_thenProvisionsUserAndReturnsCredentials() {
        // Find existing seeded request
        List<PendingRegistrationResponse> pending = service.getPendingRegistrations("site-1");
        assertFalse(pending.isEmpty());
        String reqId = pending.get(0).requestId();

        when(userRepository.save(any(UserEntity.class))).thenAnswer(inv -> inv.getArgument(0));

        ApprovalResultResponse result = service.approveRegistration(reqId);

        assertNotNull(result);
        assertEquals("APPROVED", result.status());
        assertEquals("kerem.yilmaz@gmail.com", result.residentEmail());
        assertNotNull(result.temporaryPassword());
        assertTrue(result.temporaryPassword().startsWith("SP-SAKIN-"));

        verify(userRepository, times(1)).save(any(UserEntity.class));
    }
}
