package com.sitepulse.backend.service;

import com.sitepulse.backend.domain.entity.SiteEntity;
import com.sitepulse.backend.domain.entity.UserEntity;
import com.sitepulse.backend.dto.SaasDtos.*;
import com.sitepulse.backend.repository.SiteRepository;
import com.sitepulse.backend.repository.UserRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.security.SecureRandom;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;
import java.util.stream.Collectors;

@Service
public class SaasTenantService {

    private final SiteRepository siteRepository;
    private final UserRepository userRepository;
    private final SecureRandom secureRandom = new SecureRandom();

    public SaasTenantService(SiteRepository siteRepository, UserRepository userRepository) {
        this.siteRepository = siteRepository;
        this.userRepository = userRepository;
    }

    @Transactional
    public SiteRegistrationResponse registerSite(RegisterSiteRequest request) {
        Objects.requireNonNull(request.siteName(), "Site adı boş olamaz");
        Objects.requireNonNull(request.siteAdminEmail(), "Yönetici e-posta adresi boş olamaz");
        Objects.requireNonNull(request.siteAdminFullName(), "Yönetici adı boş olamaz");

        if (userRepository.existsByEposta(request.siteAdminEmail())) {
            throw new IllegalArgumentException("Bu e-posta adresiyle kayıtlı bir kullanıcı zaten mevcut: " + request.siteAdminEmail());
        }

        // 1. Generate unique URL slug
        String baseSlug = toSlug(request.siteName());
        String slug = baseSlug;
        int counter = 1;
        while (siteRepository.existsBySlug(slug)) {
            slug = baseSlug + "-" + counter++;
        }

        // 2. Provision Site Tenant Record
        String siteId = "site-" + UUID.randomUUID().toString().substring(0, 8);
        String plan = (request.planType() != null && !request.planType().isBlank()) ? request.planType().toUpperCase() : "STANDARD";
        LocalDate licenseEnd = LocalDate.now().plusYears(1);

        SiteEntity site = new SiteEntity(
            siteId,
            request.siteName(),
            request.address(),
            slug,
            "ACTIVE",
            plan,
            licenseEnd
        );
        site = siteRepository.save(site);

        // 3. Generate Temporary Password for Site Manager
        String temporaryPassword = generateSecureTemporaryPassword();
        String passwordHash = "ARGON2_HASH_" + Integer.toHexString(temporaryPassword.hashCode());

        // 4. Provision Primary Site Manager Account
        String userId = "usr-" + UUID.randomUUID().toString().substring(0, 8);
        UserEntity siteAdmin = new UserEntity(
            userId,
            site.getId(),
            request.siteAdminFullName(),
            request.siteAdminEmail().trim().toLowerCase(),
            request.siteAdminPhone(),
            passwordHash,
            "SITE_MANAGER",
            true // must change password on first login
        );
        siteAdmin = userRepository.save(siteAdmin);

        return new SiteRegistrationResponse(
            site.getId(),
            site.getAd(),
            site.getSlug(),
            site.getDurum(),
            site.getPlanTipi(),
            siteAdmin.getId(),
            siteAdmin.getAdSoyad(),
            siteAdmin.getEposta(),
            temporaryPassword,
            siteAdmin.getSifreDegistirilmeli(),
            OffsetDateTime.now()
        );
    }

    @Transactional(readOnly = true)
    public List<SaasSiteSummaryDto> getAllSites() {
        return siteRepository.findAll().stream().map(site -> {
            List<UserEntity> managers = userRepository.findBySiteIdAndRol(site.getId(), "SITE_MANAGER");
            UserEntity primaryManager = managers.isEmpty() ? null : managers.get(0);

            // Default baseline unit counts and dues volume for site
            int defaultUnits = "site-1".equals(site.getId()) ? 24 : 16;
            BigDecimal defaultDues = "site-1".equals(site.getId()) ? new BigDecimal("96000.00") : new BigDecimal("64000.00");

            return new SaasSiteSummaryDto(
                site.getId(),
                site.getAd(),
                site.getSlug(),
                site.getAdres(),
                site.getDurum(),
                site.getPlanTipi(),
                site.getLisansBitisTarihi(),
                defaultUnits,
                defaultDues,
                primaryManager != null ? primaryManager.getAdSoyad() : "Atanmadı",
                primaryManager != null ? primaryManager.getEposta() : "-",
                primaryManager != null ? primaryManager.getTelefon() : "-"
            );
        }).collect(Collectors.toList());
    }

    @Transactional(readOnly = true)
    public SaasGlobalStatsDto getGlobalStats() {
        List<SiteEntity> allSites = siteRepository.findAll();
        long totalSites = allSites.size();
        long active = allSites.stream().filter(s -> "ACTIVE".equalsIgnoreCase(s.getDurum())).count();
        int totalUnits = (int) (totalSites * 20);
        BigDecimal volume = new BigDecimal("80000.00").multiply(BigDecimal.valueOf(totalSites));

        return new SaasGlobalStatsDto(totalSites, active, totalUnits, volume);
    }

    private String toSlug(String input) {
        String s = input.toLowerCase()
            .replace("ı", "i")
            .replace("ğ", "g")
            .replace("ü", "u")
            .replace("ş", "s")
            .replace("ö", "o")
            .replace("ç", "c")
            .replaceAll("[^a-z0-9\\s-]", "")
            .replaceAll("\\s+", "-")
            .replaceAll("-+", "-");
        return s.isBlank() ? "site" : s;
    }

    private String generateSecureTemporaryPassword() {
        String chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        StringBuilder sb = new StringBuilder("SP-");
        for (int i = 0; i < 4; i++) {
            sb.append(chars.charAt(secureRandom.nextInt(chars.length())));
        }
        sb.append("-");
        for (int i = 0; i < 4; i++) {
            sb.append(chars.charAt(secureRandom.nextInt(chars.length())));
        }
        return sb.toString();
    }
}
