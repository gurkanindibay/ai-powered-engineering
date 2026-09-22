package com.sitepulse.backend.controller;

import com.sitepulse.backend.dto.HomeOwnerDtos.HomeOwnerResponse;
import com.sitepulse.backend.dto.HomeOwnerDtos.RegisterHomeOwnerRequest;
import com.sitepulse.backend.service.SiteAdminService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1/site-admin")
@CrossOrigin(origins = "*")
public class SiteAdminController {

    private final SiteAdminService siteAdminService;

    public SiteAdminController(SiteAdminService siteAdminService) {
        this.siteAdminService = siteAdminService;
    }

    @PostMapping("/sites/{siteId}/home-owners")
    public ResponseEntity<HomeOwnerResponse> registerHomeOwner(
        @PathVariable String siteId,
        @RequestBody RegisterHomeOwnerRequest request
    ) {
        HomeOwnerResponse response = siteAdminService.registerHomeOwner(siteId, request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    @GetMapping("/sites/{siteId}/home-owners")
    public ResponseEntity<List<HomeOwnerResponse>> getHomeOwners(@PathVariable String siteId) {
        return ResponseEntity.ok(siteAdminService.getHomeOwnersForSite(siteId));
    }
}
