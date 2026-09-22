package com.sitepulse.backend.dto;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

public class HomeOwnerDtos {

    public record RegisterHomeOwnerRequest(
        String block,
        int unitNo,
        int floor,
        String ownerFullName,
        String email,
        String phone,
        String landShare,
        BigDecimal monthlyDues,
        boolean isResident
    ) {}

    public record HomeOwnerResponse(
        String unitId,
        String siteId,
        String block,
        int unitNo,
        int floor,
        String ownerFullName,
        String email,
        String phone,
        String landShare,
        BigDecimal monthlyDues,
        boolean isResident,
        String temporaryPassword,
        Boolean mustChangePassword,
        OffsetDateTime createdAt
    ) {}
}
