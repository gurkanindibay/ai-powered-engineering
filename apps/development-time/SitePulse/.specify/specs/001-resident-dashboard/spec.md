# Feature Spec: Resident & Site Manager Mobile Dashboard

> **Feature ID:** SPEC-001  
> **Module:** Sakin & Yönetici Mobil Arayüzü  
> **Status:** SPECIFIED (Awaiting Design Approval)  
> **Release Target:** Release 1 (MVP)  

---

## 1. Summary
SitePulse Release 1 strictly focuses on **Aidat Payment Tracking & Financial Transparency** and **Site Communication**. All sub-meter reading ("Sayaç Gir") and amenity reservation ("Rezervasyon") features are deferred to post-Release 1. 

Release 1 introduces dual operational roles:
1. **Resident Role (Site Sakini)**: Immediate overview of personal dues liabilities, statutory KMK delay penalty, payment receipts, announcements, and direct management inquiries.
2. **Site Manager Role (Site Yöneticisi)**: Real-time complex-wide aidat collection tracking, flat-by-flat payment status breakdown, direct resident notification/message dispatch, and site-wide announcement broadcasting.

---

## 2. Personas & Scenarios

### Persona 1: Zeynep / Ahmet (Kat Maliki / Sakin - A Blok Daire 14)
- **Goal:** Check monthly dues, view KMK statutory delay interest breakdown, pay dues via credit card, view past receipts, and read management announcements.

### Persona 2: Mehmet Bey (Site Yöneticisi / Manager)
- **Goal:** Track monthly collection progress across all flats, identify overdue residents, send targeted payment reminders / direct messages, and publish building announcements.

---

## 3. Detailed Acceptance Criteria

### Scenario 1: Resident Dues Tracking & KMK Penalty (Release 1 Scope)
- **Given** resident has an unpaid aidat of ₺1.400,00 that is 10 days past due (15th of the month),
- **When** the dashboard loads,
- **Then** calculate KMK statutory penalty ($\text{Penalty} = 1.400 \times 0.05 \times \frac{10}{30} = ₺23,33$),
- **And** display total payable as **₺1.423,33**,
- **And** return `days_overdue` for each dues item using the same server calculation date as its penalty; the client displays this day count without recalculating it from the device timezone.
- **And** render quick actions: `Aidat Öde`, `Dekontlar`, `Arıza Bildir`, `Yönetimle İletişim`.
- **And** ensure `Sayaç Gir` and `Rezervasyon` are NOT displayed in Release 1.

### Scenario 2: Site Manager Collection Tracking Dashboard
- **Given** the Site Manager logs in or switches to the Manager view,
- **When** the manager dashboard loads,
- **Then** display complex-wide collection metrics:
  - Toplam Tahakkuk (e.g. ₺120.000,00)
  - Tahsil Edilen (e.g. ₺96.000,00 - %80)
  - Kalan / Gecikmedeki Borç (e.g. ₺24.000,00 + KMK gecikme tazminatları)
  - Daire bazlı dağılım (18 Daire Ödedi, 6 Daire Gecikmede)
- **And** display a flat-by-flat list with status filters (`Tümü`, `Gecikmede`, `Ödendi`).

### Scenario 3: Site Manager Direct Message & Reminder Dispatch
- **Given** the Site Manager identifies an overdue flat (e.g. A Blok D:14),
- **When** tapping `Mesaj Gönder` or `Hatırlat`,
- **Then** open a targeted message entry modal with pre-filled resident details,
- **And** allow sending an instant push notification / direct message.

### Scenario 4: Site Manager Announcement Broadcasting
- **Given** the Site Manager needs to notify all residents,
- **When** tapping `Duyuru Yayınla`,
- **Then** open the announcement creation modal (Title, Category, Content),
- **And** broadcast immediately to the resident feed upon submission.

---

## 4. Release 1 Non-Goals
- **Deferred to v2:** Sub-meter heat/water cost allocation ("Sayaç Gir / Pay Ölçer").
- **Deferred to v2:** Common area booking calendar ("Rezervasyon").
- **Deferred to v2:** Full banking API automated reconciliation (simulated via in-app payment records in v1).
