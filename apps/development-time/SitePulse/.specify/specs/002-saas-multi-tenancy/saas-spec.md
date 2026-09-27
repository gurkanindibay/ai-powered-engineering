# Specification: SaaS Multi-Tenancy & Autonomous Site Onboarding

> **Feature ID:** SPEC-002  
> **Domain:** Multi-Tenant Residential SaaS Platform  
> **Target Roles:** SaaS Super Admin, Site Manager (Yönetici)  
> **Governance:** Tenant Isolation, Automatic Credential Provisioning  

---

## 1. Context & Business Goals

SitePulse is transitioning from a single-residential demonstration model to a **multi-tenant Software-as-a-Service (SaaS)** architecture. Following a commercial agreement/sale for a residential complex, a SaaS Super Admin must be able to register the new site into the system.

During this registration:
1. A unique tenant record (`siteler`) is provisioned with a URL-safe slug, subscription tier, and validity window.
2. The initial primary **Site Manager (Site Yöneticisi)** account is automatically created.
3. Cryptographically strong temporary credentials (email + temporary password) are instantly generated and returned for immediate handover to the customer.

---

## 2. Multi-Tenant Architectural Constraints

1. **Shared Database, Logical Isolation:**
   - Every site data entity (`bloklar`, `bagimsiz_bolumler`, `aidat_borclari`, `tahsilat_hareketleri`) strictly maintains a foreign key reference to `siteler(id)`.
   - Queries must always be scoped by `site_id` to guarantee tenant isolation.
2. **User & Identity Modeling:**
   - `UserEntity` distinguishes between:
     - `SAAS_ADMIN`: Global system administrator with cross-tenant visibility and registration authority.
     - `SITE_MANAGER`: Tenant-scoped administrator who manages resident rosters, dues collection, and announcements.
     - `RESIDENT`: Tenant-scoped resident (Kat Maliki / Kiracı).
3. **Site Admin Credential Provisioning:**
   - Default email format: Valid email provided during registration (e.g., `yonetim@palmiyesitesi.com`).
   - Temporary password: 12-character format `SP-XXXX-YYYY` containing uppercase, lowercase, and digits.
   - Status flag `must_change_password` set to `true` upon first login.

---

## 3. API Contract Specifications

### 3.1 Register New Site & Provision Site Admin
- **Endpoint:** `POST /api/v1/saas/sites`
- **Request Payload:**
```json
{
  "siteName": "Palmiye Evleri Sitesi",
  "address": "Atatürk Mah. Orkide Sok. No:12, Kadıköy, İstanbul",
  "city": "İstanbul",
  "planType": "STANDARD",
  "siteAdminFullName": "Mehmet Can",
  "siteAdminEmail": "mehmet@palmiyeevleri.com",
  "siteAdminPhone": "+90 532 555 0199"
}
```
- **Response Payload:** `201 Created`
```json
{
  "siteId": "site-9f8e7d6c",
  "siteName": "Palmiye Evleri Sitesi",
  "slug": "palmiye-evleri-sitesi",
  "status": "ACTIVE",
  "planType": "STANDARD",
  "siteAdminId": "usr-1a2b3c4d",
  "siteAdminFullName": "Mehmet Can",
  "siteAdminEmail": "mehmet@palmiyeevleri.com",
  "temporaryPassword": "SP-7X9K-M2P4",
  "mustChangePassword": true,
  "createdAt": "2026-09-22T22:55:00Z"
}
```

### 3.2 List Managed Sites
- **Endpoint:** `GET /api/v1/saas/sites`
- **Response Payload:** `200 OK`
```json
[
  {
    "siteId": "site-begonya",
    "siteName": "Begonya Sitesi",
    "slug": "begonya-sitesi",
    "city": "İstanbul",
    "status": "ACTIVE",
    "totalUnits": 24,
    "totalMonthlyDues": 96000.00,
    "siteAdminName": "Mehmet Demir",
    "siteAdminEmail": "mehmet.demir@begonya.com"
  }
]
```

### 3.3 Delete Action-Free Site (Invariant Guard)
- **Endpoint:** `DELETE /api/v1/saas/sites/{siteId}`
- **Pre-condition:** Calling actor must have `SAAS_ADMIN` role.
- **Domain Invariant & Guard Rule:**
  - A site can **ONLY** be deleted if there are **NO operational or financial actions** associated with it.
  - "No action" is defined as:
    1. Zero registered units/apartments (`totalUnits == 0`).
    2. Zero financial transactions or dues collection volume (`monthlyCollectionVolume == 0.00` and no `DuesLiability` records).
    3. Zero pending resident registrations or active tenant activity (`pendingRegistrations == 0`).
  - If any action, unit, or financial movement exists for the site, the deletion **MUST BE REJECTED** with an invariant violation error (`409 Conflict` in REST API, friendly explanation in UI).
  - If no action exists, the site and its associated unactivated tenant admin account are permanently purged from the system.

- **Acceptance Scenarios (Gherkin):**
```gherkin
Scenario: Successfully delete an action-free site
  Given a registered site "Zambak Konutları" with 0 units, 0 dues, and 0 resident registrations
  When SaaS Admin requests to delete the site
  Then the system prompts for confirmation
  When confirmation is granted
  Then the site is deleted and removed from the active tenant portfolio
  And a success notification is presented

Scenario: Attempting to delete a site with existing actions is strictly rejected
  Given a registered site "Begonya Sitesi" with active units (24) and dues volume (₺96,000.00)
  When SaaS Admin attempts to delete the site
  Then the deletion is rejected with an invariant error
  And "Begonya Sitesi" remains intact and protected in the system
```

### 3.4 Renew / Reissue Temporary Site Manager Password
- **Endpoint:** `POST /api/v1/saas/sites/{siteId}/reset-admin-password`
- **Pre-condition:** Calling actor must have `SAAS_ADMIN` role.
- **Business Need & Rationale:** Site managers may forget, lose, or fail to receive their initial onboarding credentials. SaaS Super Admins must be able to securely regenerate and reissue a temporary password on demand.
- **Domain Invariant & Guard Rule:**
  - The target site must exist and have an assigned primary Site Manager user account.
  - A new cryptographically strong temporary password (`SP-XXXX-YYYY`) is generated.
  - The user's `must_change_password` flag is reset to `true`.
  - The password hash in storage is immediately updated.
- **Response Payload:** `200 OK`
```json
{
  "siteId": "site-1",
  "siteName": "Begonya Sitesi",
  "adminUserId": "usr-site-manager-1",
  "adminFullName": "Mehmet Demir",
  "adminEmail": "mehmet.demir@begonya.com",
  "temporaryPassword": "SP-8K2L-P9Q1",
  "mustChangePassword": true,
  "renewedAt": "2026-09-27T18:25:00Z"
}
```

- **Acceptance Scenarios (Gherkin):**
```gherkin
Scenario: SaaS Admin renews temporary password for a site manager
  Given a registered site "Begonya Sitesi" with manager "Mehmet Demir"
  When SaaS Admin clicks "Şifre Yenile" and confirms
  Then a new temporary password in format "SP-XXXX-YYYY" is generated
  And the manager's account mustChangePassword flag is set to true
  And a credentials modal with copy-to-clipboard functionality appears
```

