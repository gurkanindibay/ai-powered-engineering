package com.sitepulse.backend.service;

import com.sitepulse.backend.domain.entity.UserEntity;
import com.sitepulse.backend.dto.HomeOwnerDtos.HomeOwnerResponse;
import com.sitepulse.backend.dto.HomeOwnerDtos.RegisterHomeOwnerRequest;
import com.sitepulse.backend.repository.SiteRepository;
import com.sitepulse.backend.repository.UserRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.security.SecureRandom;
import java.time.OffsetDateTime;
import java.util.*;

@Service
public class SiteAdminService {

    private final SiteRepository siteRepository;
    private final UserRepository userRepository;
    private final SecureRandom secureRandom = new SecureRandom();

    public SiteAdminService(SiteRepository siteRepository, UserRepository userRepository) {
        this.siteRepository = siteRepository;
        this.userRepository = userRepository;
    }

    @Transactional
    public HomeOwnerResponse registerHomeOwner(String siteId, RegisterHomeOwnerRequest request) {
        Objects.requireNonNull(siteId, "Site ID boş olamaz");
        Objects.requireNonNull(request.ownerFullName(), "Kat maliki adı boş olamaz");
        Objects.requireNonNull(request.email(), "Kat maliki e-posta adresi boş olamaz");
        Objects.requireNonNull(request.block(), "Blok adı boş olamaz");

        if (userRepository.existsByEposta(request.email())) {
            throw new IllegalArgumentException("Bu e-posta adresiyle kayıtlı bir kullanıcı zaten mevcut: " + request.email());
        }

        // 1. Generate secure temporary password for resident (SP-SAKIN-XXXX)
        String tempPassword = generateResidentTemporaryPassword();
        String passwordHash = "argon2id_hash_placeholder:" + tempPassword;

        // 2. Create User account for resident/owner
        String userId = "usr-resident-" + UUID.randomUUID().toString().substring(0, 8);
        UserEntity residentUser = new UserEntity(
            userId,
            siteId,
            request.ownerFullName(),
            request.email(),
            request.phone(),
            passwordHash,
            "RESIDENT",
            true
        );
        userRepository.save(residentUser);

        // 3. Generate Unit Identifier
        String unitId = "unit-" + UUID.randomUUID().toString().substring(0, 8);

        return new HomeOwnerResponse(
            unitId,
            siteId,
            request.block(),
            request.unitNo(),
            request.floor(),
            request.ownerFullName(),
            request.email(),
            request.phone(),
            request.landShare() != null ? request.landShare() : "1/24",
            request.monthlyDues() != null ? request.monthlyDues() : new BigDecimal("1400.00"),
            request.isResident(),
            tempPassword,
            true,
            OffsetDateTime.now()
        );
    }

    @Transactional(readOnly = true)
    public List<HomeOwnerResponse> getHomeOwnersForSite(String siteId) {
        List<UserEntity> residents = userRepository.findBySiteId(siteId).stream()
            .filter(u -> "RESIDENT".equalsIgnoreCase(u.getRol()))
            .toList();

        int counter = 1;
        List<HomeOwnerResponse> result = new ArrayList<>();
        for (UserEntity r : residents) {
            result.add(new HomeOwnerResponse(
                "unit-auto-" + counter,
                siteId,
                "A Blok",
                10 + counter,
                counter,
                r.getAdSoyad(),
                r.getEposta(),
                r.getTelefon(),
                "1/24",
                new BigDecimal("1400.00"),
                true,
                null,
                r.getSifreDegistirilmeli(),
                r.getCreatedAt()
            ));
            counter++;
        }
        return result;
    }

    private String generateResidentTemporaryPassword() {
        String chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        StringBuilder sb = new StringBuilder("SP-SAKIN-");
        for (int i = 0; i < 4; i++) {
            sb.append(chars.charAt(secureRandom.nextInt(chars.length())));
        }
        return sb.toString();
    }
}
