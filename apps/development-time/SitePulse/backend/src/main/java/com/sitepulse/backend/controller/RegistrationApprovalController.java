package com.sitepulse.backend.controller;

import com.sitepulse.backend.dto.RegistrationRequestDtos.*;
import com.sitepulse.backend.service.RegistrationApprovalService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@CrossOrigin(origins = "*")
public class RegistrationApprovalController {

    private final RegistrationApprovalService approvalService;

    public RegistrationApprovalController(RegistrationApprovalService approvalService) {
        this.approvalService = approvalService;
    }

    @PostMapping("/api/v1/site-admin/sites/{siteId}/invite-link")
    public ResponseEntity<SiteInvitationLinkResponse> generateInviteLink(@PathVariable String siteId) {
        return ResponseEntity.ok(approvalService.generateInvitationLink(siteId));
    }

    @PostMapping("/api/v1/public/sites/{slug}/join")
    public ResponseEntity<PendingRegistrationResponse> submitSelfRegistration(
        @PathVariable String slug,
        @RequestBody SubmitSelfRegistrationRequest request
    ) {
        PendingRegistrationResponse response = approvalService.submitSelfRegistration(slug, request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    @GetMapping("/api/v1/site-admin/sites/{siteId}/pending-registrations")
    public ResponseEntity<List<PendingRegistrationResponse>> getPendingRegistrations(@PathVariable String siteId) {
        return ResponseEntity.ok(approvalService.getPendingRegistrations(siteId));
    }

    @PostMapping("/api/v1/site-admin/registrations/{requestId}/approve")
    public ResponseEntity<ApprovalResultResponse> approveRegistration(@PathVariable String requestId) {
        return ResponseEntity.ok(approvalService.approveRegistration(requestId));
    }

    @PostMapping("/api/v1/site-admin/registrations/{requestId}/reject")
    public ResponseEntity<PendingRegistrationResponse> rejectRegistration(
        @PathVariable String requestId,
        @RequestParam(required = false, defaultValue = "Yönetim tarafından onaylanmadı") String reason
    ) {
        return ResponseEntity.ok(approvalService.rejectRegistration(requestId, reason));
    }
}
