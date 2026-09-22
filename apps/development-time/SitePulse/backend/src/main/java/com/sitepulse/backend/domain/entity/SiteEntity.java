package com.sitepulse.backend.domain.entity;

import jakarta.persistence.*;
import java.time.LocalDate;
import java.time.OffsetDateTime;

@Entity
@Table(name = "siteler")
public class SiteEntity {

    @Id
    @Column(length = 36)
    private String id;

    @Column(nullable = false, length = 150)
    private String ad;

    @Column(columnDefinition = "TEXT")
    private String adres;

    @Column(unique = true, length = 180)
    private String slug;

    @Column(nullable = false, length = 30)
    private String durum; // 'ACTIVE', 'TRIAL', 'SUSPENDED'

    @Column(name = "plan_tipi", nullable = false, length = 50)
    private String planTipi; // 'STANDARD', 'PREMIUM', 'ENTERPRISE'

    @Column(name = "lisans_bitis_tarihi")
    private LocalDate lisansBitisTarihi;

    @Column(name = "created_at")
    private OffsetDateTime createdAt;

    public SiteEntity() {}

    public SiteEntity(String id, String ad, String adres, String slug, String durum, String planTipi, LocalDate lisansBitisTarihi) {
        this.id = id;
        this.ad = ad;
        this.adres = adres;
        this.slug = slug;
        this.durum = durum;
        this.planTipi = planTipi;
        this.lisansBitisTarihi = lisansBitisTarihi;
        this.createdAt = OffsetDateTime.now();
    }

    public String getId() { return id; }
    public void setId(String id) { this.id = id; }

    public String getAd() { return ad; }
    public void setAd(String ad) { this.ad = ad; }

    public String getAdres() { return adres; }
    public void setAdres(String adres) { this.adres = adres; }

    public String getSlug() { return slug; }
    public void setSlug(String slug) { this.slug = slug; }

    public String getDurum() { return durum; }
    public void setDurum(String durum) { this.durum = durum; }

    public String getPlanTipi() { return planTipi; }
    public void setPlanTipi(String planTipi) { this.planTipi = planTipi; }

    public LocalDate getLisansBitisTarihi() { return lisansBitisTarihi; }
    public void setLisansBitisTarihi(LocalDate lisansBitisTarihi) { this.lisansBitisTarihi = lisansBitisTarihi; }

    public OffsetDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(OffsetDateTime createdAt) { this.createdAt = createdAt; }
}
