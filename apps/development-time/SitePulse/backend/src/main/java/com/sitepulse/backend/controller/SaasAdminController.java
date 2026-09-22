package com.sitepulse.backend.controller;

import com.sitepulse.backend.dto.SaasDtos.*;
import com.sitepulse.backend.service.SaasTenantService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1/saas")
@CrossOrigin(origins = "*")
public class SaasAdminController {

    private final SaasTenantService saasTenantService;

    public SaasAdminController(SaasTenantService saasTenantService) {
        this.saasTenantService = saasTenantService;
    }

    @PostMapping("/sites")
    public ResponseEntity<SiteRegistrationResponse> registerNewSite(@RequestBody RegisterSiteRequest request) {
        SiteRegistrationResponse response = saasTenantService.registerSite(request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    @GetMapping("/sites")
    public ResponseEntity<List<SaasSiteSummaryDto>> getAllSites() {
        return ResponseEntity.ok(saasTenantService.getAllSites());
    }

    @GetMapping("/stats")
    public ResponseEntity<SaasGlobalStatsDto> getGlobalStats() {
        return ResponseEntity.ok(saasTenantService.getGlobalStats());
    }
}
