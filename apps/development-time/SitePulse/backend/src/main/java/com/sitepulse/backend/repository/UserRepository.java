package com.sitepulse.backend.repository;

import com.sitepulse.backend.domain.entity.UserEntity;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

@Repository
public interface UserRepository extends JpaRepository<UserEntity, String> {
    Optional<UserEntity> findByEposta(String eposta);
    Optional<UserEntity> findByGoogleSub(String googleSub);
    boolean existsByEposta(String eposta);
    List<UserEntity> findBySiteIdAndRol(String siteId, String rol);
    List<UserEntity> findBySiteId(String siteId);
}
