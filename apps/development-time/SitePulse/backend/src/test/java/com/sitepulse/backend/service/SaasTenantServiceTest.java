package com.sitepulse.backend.service;

import com.sitepulse.backend.domain.entity.SiteEntity;
import com.sitepulse.backend.domain.entity.UserEntity;
import com.sitepulse.backend.dto.SaasDtos.RegisterSiteRequest;
import com.sitepulse.backend.dto.SaasDtos.SiteRegistrationResponse;
import com.sitepulse.backend.repository.SiteRepository;
import com.sitepulse.backend.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class SaasTenantServiceTest {

    private SiteRepository siteRepository;
    private UserRepository userRepository;
    private SaasTenantService service;

    @BeforeEach
    void setUp() {
        siteRepository = Mockito.mock(SiteRepository.class);
        userRepository = Mockito.mock(UserRepository.class);
        service = new SaasTenantService(siteRepository, userRepository);
    }

    @Test
    void whenRegisteringNewSite_thenProvisionsSiteAndManagerWithTemporaryPassword() {
        RegisterSiteRequest request = new RegisterSiteRequest(
            "Palmiye Evleri Sitesi",
            "Atatürk Mah. Orkide Sok. No:12, Kadıköy, İstanbul",
            "İstanbul",
            "PREMIUM",
            "Mehmet Can",
            "mehmet@palmiyeevleri.com",
            "+90 532 555 0199"
        );

        when(userRepository.existsByEposta("mehmet@palmiyeevleri.com")).thenReturn(false);
        when(siteRepository.existsBySlug(any())).thenReturn(false);
        when(siteRepository.save(any(SiteEntity.class))).thenAnswer(inv -> inv.getArgument(0));
        when(userRepository.save(any(UserEntity.class))).thenAnswer(inv -> inv.getArgument(0));

        SiteRegistrationResponse response = service.registerSite(request);

        assertNotNull(response);
        assertEquals("Palmiye Evleri Sitesi", response.siteName());
        assertEquals("palmiye-evleri-sitesi", response.slug());
        assertEquals("PREMIUM", response.planType());
        assertEquals("ACTIVE", response.status());
        assertEquals("Mehmet Can", response.siteAdminFullName());
        assertEquals("mehmet@palmiyeevleri.com", response.siteAdminEmail());
        assertTrue(response.temporaryPassword().startsWith("SP-"));
        assertEquals(12, response.temporaryPassword().length()); // SP-XXXX-YYYY
        assertTrue(response.mustChangePassword());

        verify(siteRepository, times(1)).save(any(SiteEntity.class));
        verify(userRepository, times(1)).save(any(UserEntity.class));
    }

    @Test
    void whenDuplicateEmail_thenThrowsException() {
        RegisterSiteRequest request = new RegisterSiteRequest(
            "Palmiye Evleri Sitesi",
            "Adres",
            "İstanbul",
            "STANDARD",
            "Mehmet Can",
            "existing@email.com",
            "+90 532 555 0199"
        );

        when(userRepository.existsByEposta("existing@email.com")).thenReturn(true);

        assertThrows(IllegalArgumentException.class, () -> service.registerSite(request));
        verify(siteRepository, never()).save(any());
        verify(userRepository, never()).save(any());
    }
}
