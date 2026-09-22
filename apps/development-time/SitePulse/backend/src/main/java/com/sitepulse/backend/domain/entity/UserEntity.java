package com.sitepulse.backend.domain.entity;

import jakarta.persistence.*;
import java.time.OffsetDateTime;

@Entity
@Table(name = "kullanicilar")
public class UserEntity {

    @Id
    @Column(length = 36)
    private String id;

    @Column(name = "site_id", length = 36)
    private String siteId;

    @Column(name = "ad_soyad", nullable = false, length = 120)
    private String adSoyad;

    @Column(nullable = false, unique = true, length = 120)
    private String eposta;

    @Column(length = 20)
    private String telefon;

    @Column(name = "sifre_hash")
    private String sifreHash;

    @Column(nullable = false, length = 30)
    private String rol; // 'SAAS_ADMIN', 'SITE_MANAGER', 'HOME_OWNER', 'HOME_RESIDENT'

    @Column(name = "sifre_degistirilmeli", nullable = false)
    private Boolean sifreDegistirilmeli = false;

    @Column(name = "auth_provider", nullable = false, length = 30)
    private String authProvider = "LOCAL"; // 'LOCAL', 'GOOGLE', 'HYBRID'

    @Column(name = "google_sub", length = 100)
    private String googleSub;

    @Column(name = "avatar_url", length = 500)
    private String avatarUrl;

    @Column(name = "created_at")
    private OffsetDateTime createdAt;

    public UserEntity() {}

    public UserEntity(String id, String siteId, String adSoyad, String eposta, String telefon, String sifreHash, String rol, Boolean sifreDegistirilmeli) {
        this(id, siteId, adSoyad, eposta, telefon, sifreHash, rol, sifreDegistirilmeli, "LOCAL", null, null);
    }

    public UserEntity(String id, String siteId, String adSoyad, String eposta, String telefon, String sifreHash, String rol, Boolean sifreDegistirilmeli, String authProvider, String googleSub, String avatarUrl) {
        this.id = id;
        this.siteId = siteId;
        this.adSoyad = adSoyad;
        this.eposta = eposta;
        this.telefon = telefon;
        this.sifreHash = sifreHash;
        this.rol = rol;
        this.sifreDegistirilmeli = sifreDegistirilmeli;
        this.authProvider = authProvider != null ? authProvider : "LOCAL";
        this.googleSub = googleSub;
        this.avatarUrl = avatarUrl;
        this.createdAt = OffsetDateTime.now();
    }

    public String getId() { return id; }
    public void setId(String id) { this.id = id; }

    public String getSiteId() { return siteId; }
    public void setSiteId(String siteId) { this.siteId = siteId; }

    public String getAdSoyad() { return adSoyad; }
    public void setAdSoyad(String adSoyad) { this.adSoyad = adSoyad; }

    public String getEposta() { return eposta; }
    public void setEposta(String eposta) { this.eposta = eposta; }

    public String getTelefon() { return telefon; }
    public void setTelefon(String telefon) { this.telefon = telefon; }

    public String getSifreHash() { return sifreHash; }
    public void setSifreHash(String sifreHash) { this.sifreHash = sifreHash; }

    public String getRol() { return rol; }
    public void setRol(String rol) { this.rol = rol; }

    public Boolean getSifreDegistirilmeli() { return sifreDegistirilmeli; }
    public void setSifreDegistirilmeli(Boolean sifreDegistirilmeli) { this.sifreDegistirilmeli = sifreDegistirilmeli; }

    public String getAuthProvider() { return authProvider; }
    public void setAuthProvider(String authProvider) { this.authProvider = authProvider; }

    public String getGoogleSub() { return googleSub; }
    public void setGoogleSub(String googleSub) { this.googleSub = googleSub; }

    public String getAvatarUrl() { return avatarUrl; }
    public void setAvatarUrl(String avatarUrl) { this.avatarUrl = avatarUrl; }

    public OffsetDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(OffsetDateTime createdAt) { this.createdAt = createdAt; }
}
