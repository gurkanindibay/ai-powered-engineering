package com.sitepulse.backend.service;

import com.sitepulse.backend.domain.entity.SiteEntity;
import com.sitepulse.backend.domain.entity.UserEntity;
import com.sitepulse.backend.dto.RegistrationRequestDtos.*;
import com.sitepulse.backend.repository.SiteRepository;
import com.sitepulse.backend.repository.UserRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.security.SecureRandom;
import java.time.OffsetDateTime;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

@Service
public class RegistrationApprovalService {

    private final SiteRepository siteRepository;
    private final UserRepository userRepository;
    private final SecureRandom secureRandom = new SecureRandom();

    // In-memory store for pending requests (or backed by repository in production)
    private final Map<String, PendingRegistrationResponse> pendingRequests = new ConcurrentHashMap<>();

    public RegistrationApprovalService(SiteRepository siteRepository, UserRepository userRepository) {
        this.siteRepository = siteRepository;
        this.userRepository = userRepository;

        // Seed an initial pending request for Begonya Sitesi
        String seedId = "req-seed-01";
        pendingRequests.put(seedId, new PendingRegistrationResponse(
            seedId,
            "site-1",
            "B Blok",
            18,
            5,
            "Kerem Yılmaz",
            "kerem.yilmaz@gmail.com",
            "+90 533 111 22 33",
            true,
            "PENDING",
            OffsetDateTime.now().minusHours(2)
        ));
    }

    public SiteInvitationLinkResponse generateInvitationLink(String siteId) {
        Optional<SiteEntity> siteOpt = siteRepository.findById(siteId);
        String siteName = siteOpt.map(SiteEntity::getAd).orElse("Begonya Sitesi");
        String slug = siteOpt.map(SiteEntity::getSlug).orElse("begonya-sitesi");

        String token = "SP-INV-" + UUID.randomUUID().toString().substring(0, 6).toUpperCase();
        String joinUrl = "https://sitepulse.app/join/" + slug + "?token=" + token;
        OffsetDateTime expiresAt = OffsetDateTime.now().plusDays(7);

        return new SiteInvitationLinkResponse(siteId, siteName, slug, token, joinUrl, expiresAt);
    }

    public PendingRegistrationResponse submitSelfRegistration(String slug, SubmitSelfRegistrationRequest request) {
        Objects.requireNonNull(request.fullName(), "Ad Soyad boş olamaz");
        Objects.requireNonNull(request.email(), "E-posta boş olamaz");
        Objects.requireNonNull(request.block(), "Blok adı boş olamaz");

        if (userRepository.existsByEposta(request.email())) {
            throw new IllegalArgumentException("Bu e-posta adresiyle zaten kayıtlı bir kullanıcı bulunmaktadır: " + request.email());
        }

        String requestId = "req-" + UUID.randomUUID().toString().substring(0, 8);
        Optional<SiteEntity> siteOpt = siteRepository.findBySlug(slug);
        String siteId = siteOpt.map(SiteEntity::getId).orElse("site-1");

        PendingRegistrationResponse item = new PendingRegistrationResponse(
            requestId,
            siteId,
            request.block(),
            request.unitNo(),
            request.floor(),
            request.fullName(),
            request.email(),
            request.phone(),
            request.isResident(),
            "PENDING",
            OffsetDateTime.now()
        );

        pendingRequests.put(requestId, item);
        return item;
    }

    public List<PendingRegistrationResponse> getPendingRegistrations(String siteId) {
        return pendingRequests.values().stream()
            .filter(r -> r.siteId().equalsIgnoreCase(siteId) && "PENDING".equalsIgnoreCase(r.status()))
            .sorted(Comparator.comparing(PendingRegistrationResponse::submittedAt).reversed())
            .toList();
    }

    @Transactional
    public ApprovalResultResponse approveRegistration(String requestId) {
        PendingRegistrationResponse req = pendingRequests.get(requestId);
        if (req == null) {
            throw new NoSuchElementException("Kayıt başvurusu bulunamadı: " + requestId);
        }

        if (!"PENDING".equalsIgnoreCase(req.status())) {
            throw new IllegalStateException("Bu başvuru daha önce işlenmiştir: " + req.status());
        }

        // 1. Generate resident password
        String tempPassword = generateResidentTemporaryPassword();
        String passwordHash = "argon2id_hash_placeholder:" + tempPassword;

        // 2. Provision resident account
        String userId = "usr-resident-" + UUID.randomUUID().toString().substring(0, 8);
        UserEntity residentUser = new UserEntity(
            userId,
            req.siteId(),
            req.fullName(),
            req.email(),
            req.phone(),
            passwordHash,
            "RESIDENT",
            true
        );
        userRepository.save(residentUser);

        // 3. Mark as approved
        PendingRegistrationResponse approvedReq = new PendingRegistrationResponse(
            req.requestId(),
            req.siteId(),
            req.block(),
            req.unitNo(),
            req.floor(),
            req.fullName(),
            req.email(),
            req.phone(),
            req.isResident(),
            "APPROVED",
            req.submittedAt()
        );
        pendingRequests.put(requestId, approvedReq);

        String unitId = "unit-" + UUID.randomUUID().toString().substring(0, 8);

        return new ApprovalResultResponse(
            requestId,
            req.siteId(),
            "APPROVED",
            unitId,
            req.email(),
            tempPassword,
            OffsetDateTime.now()
        );
    }

    public PendingRegistrationResponse rejectRegistration(String requestId, String reason) {
        PendingRegistrationResponse req = pendingRequests.get(requestId);
        if (req == null) {
            throw new NoSuchElementException("Kayıt başvurusu bulunamadı: " + requestId);
        }

        PendingRegistrationResponse rejectedReq = new PendingRegistrationResponse(
            req.requestId(),
            req.siteId(),
            req.block(),
            req.unitNo(),
            req.floor(),
            req.fullName(),
            req.email(),
            req.phone(),
            req.isResident(),
            "REJECTED",
            req.submittedAt()
        );
        pendingRequests.put(requestId, rejectedReq);
        return rejectedReq;
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
