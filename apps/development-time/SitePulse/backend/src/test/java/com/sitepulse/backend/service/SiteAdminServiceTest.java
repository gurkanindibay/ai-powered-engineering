package com.sitepulse.backend.service;

import com.sitepulse.backend.domain.entity.UserEntity;
import com.sitepulse.backend.dto.HomeOwnerDtos.HomeOwnerResponse;
import com.sitepulse.backend.dto.HomeOwnerDtos.RegisterHomeOwnerRequest;
import com.sitepulse.backend.repository.SiteRepository;
import com.sitepulse.backend.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

public class SiteAdminServiceTest {

    private SiteRepository siteRepository;
    private UserRepository userRepository;
    private SiteAdminService service;

    @BeforeEach
    void setUp() {
        siteRepository = Mockito.mock(SiteRepository.class);
        userRepository = Mockito.mock(UserRepository.class);
        service = new SiteAdminService(siteRepository, userRepository);
    }

    @Test
    void whenRegisteringHomeOwner_thenProvisionsUserWithResidentPassword() {
        RegisterHomeOwnerRequest request = new RegisterHomeOwnerRequest(
            "B Blok",
            16,
            4,
            "Zeynep Çelik",
            "zeynep.celik@gmail.com",
            "+90 532 987 65 43",
            "10/240",
            new BigDecimal("1400.00"),
            true
        );

        when(userRepository.existsByEposta("zeynep.celik@gmail.com")).thenReturn(false);
        when(userRepository.save(any(UserEntity.class))).thenAnswer(inv -> inv.getArgument(0));

        HomeOwnerResponse response = service.registerHomeOwner("site-1", request);

        assertNotNull(response);
        assertEquals("B Blok", response.block());
        assertEquals(16, response.unitNo());
        assertEquals(4, response.floor());
        assertEquals("Zeynep Çelik", response.ownerFullName());
        assertEquals("zeynep.celik@gmail.com", response.email());
        assertEquals(new BigDecimal("1400.00"), response.monthlyDues());
        assertTrue(response.isResident());
        assertNotNull(response.temporaryPassword());
        assertTrue(response.temporaryPassword().startsWith("SP-SAKIN-"));
        assertTrue(response.mustChangePassword());

        verify(userRepository, times(1)).save(any(UserEntity.class));
    }

    @Test
    void whenDuplicateEmailForHomeOwner_thenThrowsException() {
        RegisterHomeOwnerRequest request = new RegisterHomeOwnerRequest(
            "A Blok",
            20,
            5,
            "Ali Demir",
            "ali.demir@begonya.com",
            "+90 532 111 22 33",
            "1/24",
            new BigDecimal("1400.00"),
            true
        );

        when(userRepository.existsByEposta("ali.demir@begonya.com")).thenReturn(true);

        assertThrows(IllegalArgumentException.class, () -> service.registerHomeOwner("site-1", request));
        verify(userRepository, never()).save(any(UserEntity.class));
    }
}
