package com.sitepulse.backend.controller;

import com.sitepulse.backend.dto.UnitInvitationDtos.*;
import com.sitepulse.backend.service.HomeResidentInvitationService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1")
@CrossOrigin(origins = "*")
public class HomeResidentInvitationController {

    private final HomeResidentInvitationService invitationService;

    public HomeResidentInvitationController(HomeResidentInvitationService invitationService) {
        this.invitationService = invitationService;
    }

    /**
     * Home Owner generates an invite link specifically for their unit.
     */
    @PostMapping("/residents/units/{unitId}/invite-link")
    public ResponseEntity<UnitInviteLinkResponse> generateUnitInviteLink(
            @PathVariable String unitId,
            @RequestBody(required = false) GenerateUnitInviteRequest request
    ) {
        String relationship = (request != null) ? request.relationship() : "Aile Üyesi / Sakin";
        UnitInviteLinkResponse response = invitationService.generateUnitInviteLink(unitId, relationship);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    /**
     * Co-resident / family member clicks the link and registers.
     * Permissions are strictly bound to this specific unit.
     */
    @PostMapping("/public/units/join")
    public ResponseEntity<HomeResidentResponse> registerHomeResident(
            @RequestBody RegisterHomeResidentRequest request
    ) {
        HomeResidentResponse response = invitationService.registerHomeResident(request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    /**
     * Lists registered household members for this specific flat.
     */
    @GetMapping("/residents/units/{unitId}/members")
    public ResponseEntity<List<UnitMemberDto>> getUnitMembers(@PathVariable String unitId) {
        List<UnitMemberDto> members = invitationService.getUnitMembers(unitId);
        return ResponseEntity.ok(members);
    }
}
