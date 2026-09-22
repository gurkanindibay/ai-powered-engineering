package com.sitepulse.backend.repository;

import com.sitepulse.backend.domain.entity.SiteEntity;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.Optional;

@Repository
public interface SiteRepository extends JpaRepository<SiteEntity, String> {
    Optional<SiteEntity> findBySlug(String slug);
    boolean existsBySlug(String slug);
}
