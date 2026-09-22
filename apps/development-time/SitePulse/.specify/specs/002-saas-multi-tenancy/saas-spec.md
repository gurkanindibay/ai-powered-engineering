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
