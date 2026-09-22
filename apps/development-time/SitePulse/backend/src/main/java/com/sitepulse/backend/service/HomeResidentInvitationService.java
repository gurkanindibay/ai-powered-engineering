package com.sitepulse.backend.service;

import com.sitepulse.backend.domain.entity.BagimsizBolumEntity;
import com.sitepulse.backend.domain.entity.UserEntity;
import com.sitepulse.backend.dto.UnitInvitationDtos.*;
import com.sitepulse.backend.repository.BagimsizBolumRepository;
import com.sitepulse.backend.repository.UserRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.security.SecureRandom;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

@Service
public class HomeResidentInvitationService {

    private final BagimsizBolumRepository bagimsizBolumRepository;
    private final UserRepository userRepository;
    private final SecureRandom secureRandom = new SecureRandom();

    // Map of token -> TokenMetadata
    private final Map<String, UnitTokenInfo> activeTokens = new ConcurrentHashMap<>();

    // Map of unitId -> list of registered household members
    private final Map<String, List<UnitMemberDto>> unitMembers = new ConcurrentHashMap<>();

    public record UnitTokenInfo(
            String token,
            String unitId,
            String building,
            String unitNumber,
            String relationship,
            Instant expiresAt
    ) {}

    public HomeResidentInvitationService(BagimsizBolumRepository bagimsizBolumRepository, UserRepository userRepository) {
        this.bagimsizBolumRepository = bagimsizBolumRepository;
        this.userRepository = userRepository;

        // Seed initial unit member (Ahmet Yılmaz - Owner of d-14 / A Blok D:14)
        List<UnitMemberDto> initialMembers = new ArrayList<>();
        initialMembers.add(new UnitMemberDto(
                "usr-ahmet-14",
                "Ahmet Yılmaz",
                "Kat Maliki (Ev Sahibi)",
                "+90 532 111 22 33",
                "ahmet.yilmaz@begonya.com",
                true
        ));
        unitMembers.put("d-14", initialMembers);
    }

    public UnitInviteLinkResponse generateUnitInviteLink(String unitId, String relationship) {
        String building = "A Blok";
        String unitNumber = "14";

        if (bagimsizBolumRepository != null) {
            Optional<BagimsizBolumEntity> unitOpt = bagimsizBolumRepository.findById(unitId);
            if (unitOpt.isPresent()) {
                building = (unitOpt.get().getBlokId() != null) ? unitOpt.get().getBlokId() : "A Blok";
                unitNumber = String.valueOf(unitOpt.get().getDaireNo());
            }
        }

        String token = "SP-HANE-" + UUID.randomUUID().toString().substring(0, 6).toUpperCase();
        String inviteUrl = "https://sitepulse.app/join/begonya-sitesi/units/" + unitId + "?token=" + token;
        Instant expiresAt = Instant.now().plus(7, ChronoUnit.DAYS);

        String rel = (relationship == null || relationship.isBlank()) ? "Aile Üyesi / Sakin" : relationship;
        String securityNotice = "Bu link sadece " + building + " D:" + unitNumber + " yetkisi tanımlar. Başka daire bilgilerine veya yönetim fonksiyonlarına erişemez.";

        UnitTokenInfo info = new UnitTokenInfo(token, unitId, building, unitNumber, rel, expiresAt);
        activeTokens.put(token, info);

        return new UnitInviteLinkResponse(
                inviteUrl,
                token,
                unitId,
                building,
                unitNumber,
                rel,
                expiresAt,
                securityNotice
        );
    }

    @Transactional
    public HomeResidentResponse registerHomeResident(RegisterHomeResidentRequest request) {
        Objects.requireNonNull(request.token(), "Davet token'ı gereklidir");
        Objects.requireNonNull(request.fullName(), "Ad Soyad gereklidir");
        Objects.requireNonNull(request.email(), "E-posta gereklidir");

        UnitTokenInfo tokenInfo = activeTokens.get(request.token());
        String unitId = (tokenInfo != null) ? tokenInfo.unitId() : "d-14";
        String relationship = (tokenInfo != null && tokenInfo.relationship() != null)
                ? tokenInfo.relationship()
                : (request.relationship() != null ? request.relationship() : "Sakin / Aile Üyesi");

        // Validate email uniqueness in DB if repo available
        if (userRepository != null && userRepository.existsByEposta(request.email())) {
            throw new IllegalArgumentException("Bu e-posta adresiyle kayıtlı bir kullanıcı zaten mevcut: " + request.email());
        }

        String residentId = "usr-res-" + UUID.randomUUID().toString().substring(0, 8);
        String tempPassword = generateTemporaryPassword();

        // If DB available, persist user with RESIDENT role
        if (userRepository != null) {
            UserEntity user = new UserEntity();
            user.setId(residentId);
            user.setAdSoyad(request.fullName());
            user.setEposta(request.email());
            user.setTelefon(request.phone());
            user.setRol("RESIDENT");
            user.setSifreHash("HASH_" + tempPassword);
            user.setSifreDegistirilmeli(true);
            userRepository.save(user);
        }

        // Add to active household members list
        unitMembers.computeIfAbsent(unitId, k -> new ArrayList<>()).add(new UnitMemberDto(
                residentId,
                request.fullName(),
                relationship,
                request.phone() != null ? request.phone() : "-",
                request.email(),
                false
        ));

        return new HomeResidentResponse(
                residentId,
                request.fullName(),
                request.email(),
                request.phone(),
                unitId,
                "HOME_RESIDENT",
                tempPassword,
                "UNIT_ONLY (" + unitId + ")",
                Instant.now()
        );
    }

    public List<UnitMemberDto> getUnitMembers(String unitId) {
        return Collections.unmodifiableList(unitMembers.getOrDefault(unitId, Collections.emptyList()));
    }

    private String generateTemporaryPassword() {
        String chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        StringBuilder sb = new StringBuilder("SP-HANE-");
        for (int i = 0; i < 4; i++) {
            sb.append(chars.charAt(secureRandom.nextInt(chars.length())));
        }
        return sb.toString();
    }
}
