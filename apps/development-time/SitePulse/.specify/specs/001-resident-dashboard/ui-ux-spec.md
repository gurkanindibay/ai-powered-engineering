# UI/UX Specification: Resident Mobile Dashboard (Papara Fintech Style)

> **Feature ID:** SPEC-001  
> **Platform:** Android (Jetpack Compose)  
> **Design Language:** Modern Fintech (Papara Style)  
> **Theme Mode:** Parametric Dual-Theme (Light & Midnight Dark)  
> **Currency Invariant:** Exclusively Turkish Lira (`₺` / TRY)  

---

## 1. Currency & Financial Invariants
- **Exclusive Currency:** All dues, penalties, balances, and payment amounts MUST be formatted and calculated strictly in **Turkish Lira (`₺`)**.
- **No Foreign Currencies:** The system does not support or display foreign currencies (USD, EUR, Gold). All carousel/pager multi-account indicators indicating currency switching are strictly prohibited.
- **Precision Standard:** All financial values must maintain high-precision `BigDecimal` / `NUMERIC(15,2)` precision to adhere to KMK statutory delay interest rules without floating-point error.

---

## 2. Parametric Dual-Theme System (Light & Dark)

Theme selection is user-configurable from the **Profile** module and applies across all surfaces parametrically:

| Token Key | Papara Light Theme | Papara Midnight Dark Theme |
| :--- | :--- | :--- |
| `CanvasBackground` | `#F8F9FA` | `#0B0F17` |
| `CardSurface` | `#FFFFFF` | `#141A29` |
| `SurfaceBorder` | `#EBECEF` | `#222D42` |
| `SurfaceMuted` | `#F3F4F6` | `#1B2337` |
| `TextPrimary` | `#0F172A` | `#F8FAFC` |
| `TextSecondary` | `#64748B` | `#94A3B8` |
| `TextMuted` | `#94A3B8` | `#64748B` |
| `PrimaryActionBg` | `#111827` | `#F8FAFC` |
| `PrimaryActionText` | `#FFFFFF` | `#0B0F17` |
| `SecondaryActionBg` | `#F3F4F6` | `#1E283D` |
| `SecondaryActionText`| `#0F172A` | `#F8FAFC` |
| `AccentRed (Overdue)`| `#FF3B30` | `#FF453A` (soft glow bg) |
| `SuccessGreen (Paid)`| `#10B981` | `#34D399` (soft glow bg) |
| `NavActive` | `#111827` | `#38BDF8` (Sky blue active) |
| `NavInactive` | `#64748B` | `#64748B` |

---

---

## 3. Resident Screen Architecture (Release 1 Scope)
- **Ergonomics & Layout Hierarchy:**
  1. **Top Bar**:
     - Left: Menu with badge + Messages with unread badge.
     - Right: Resident name, Apartment unit link, circular initials avatar (`AY`).
  2. **Circular Action Stories (Release 1 Scope - 4 Focused Actions)**:
     - `💳 Aidat Öde`: Instant credit card 3D Secure payment flow.
     - `🧾 Dekontlar`: Payment receipts and past financial archive.
     - `🔧 Arıza Bildir`: Maintenance and malfunction reporting ticket.
     - `🏢 Yönetim`: Direct messaging and contact channel with management.
     - *(Note: "Sayaç Gir" and "Rezervasyon" excluded from Release 1).*
  3. **Hero Account / Financial Card**:
     - Single currency header chip: `🇹🇷 Türk Lirası Aidat Hesabı`.
     - Overdue status pill (`10 Gün Gecikme`) or Borçsuz (`Borçsuz`).
     - Large balance display: **₺1.423,33** (or **₺0,00**).
     - Due date note: *Son Ödeme: 15 Eylül 2026 (%5 yasal faiz dahil)*.
     - Side-by-side action pills: `💳 Hemen Öde` (Solid) + `📋 Detay Gör` (Soft).
     - *No carousel pager dots.*
  4. **Announcements Feed (`DUYURULAR →`)**:
     - Notices with circular speaker icon, unread indicator dot, and timestamp.
  5. **Recent Transactions Feed (`HESAP HAREKETLERİ →`)**:
     - Itemized list with apartment dues, statutory KMK delay penalty, and payment receipts.
  6. **Bottom Navigation Bar**:
     - `Ana Sayfa`, `Aidatlar`, `Talepler`, `Duyurular`, `Profil`.

---

## 4. Site Manager (Yönetici) Dashboard Architecture
- **Header Profile**:
  - Left: Quick management menu + unread resident message counter.
  - Right: `Mehmet Demir • Begonya Sitesi Yönetim Kurulu (MD)`.
- **Manager Quick Actions (Circular Icons)**:
  - `📢 Duyuru Yayınla`: Launches Broadcast Announcement Modal.
  - `💬 Mesaj Gönder`: Launches Direct Resident Notification Modal.
  - `📋 Aidat Listesi`: Opens comprehensive flat-by-flat dues tracking ledger.
  - `🏦 Kasa / Rapor`: Real-time financial collection overview.
- **Hero Dues Collection Card (`TAHSİLAT DURUMU`)**:
  - Header: `🇹🇷 Begonya Sitesi • Eylül 2026 Tahsilat Durumu`.
  - Progress Bar & Big Figure: **₺96.000,00** / ₺120.000,00 (%80 Tahsilat).
  - Summary Metrics:
    - **18 Daire Ödedi** (Yeşil etiket - ₺96.000)
    - **6 Daire Gecikmede** (Kırmızı etiket - ₺24.000 + KMK gecikme faizleri).
  - Actions: `📢 Toplu Gecikme Hatırlatması` + `📊 Liste Filtrele`.
- **Daire Bazlı Aidat Takip Listesi (`DAİRE AİDAT DURUMLARI`)**:
  - Filter pills: `Tümü (24)`, `Gecikenler (6)`, `Ödeyenler (18)`.
  - Flat items:
    - *A Blok D:14 - Ahmet Yılmaz* (Gecikmede: 10 Gün, ₺1.423,33) → Action: `[💬 Hatırlat]`
    - *A Blok D:15 - Fatma Kaya* (Gecikmede: 5 Gün, ₺1.411,67) → Action: `[💬 Hatırlat]`
    - *A Blok D:1 - Selim Ak* (Ödendi: ₺1.400,00 - 12 Eyl) → Status: `[✔ Ödendi]`
- **Interactive Manager Modals**:
  1. **Duyuru Yayınlama Modalı (Announcement Modal)**:
     - Title (`Başlık`), Category (`Genel`, `Acil / Kesinti`, `Mali Bilgilendirme`), Body text, and `Duyuruyu Yayınla` broadcast CTA.
  2. **Doğrudan Mesaj / Bildirim Modalı (Direct Message Modal)**:
     - Target Flat selector (`A Blok D:14 - Ahmet Yılmaz`), Message Template / Type (`Gecikmiş Aidat Hatırlatması`, `Özel Mesaj`), Message content, and `Bildirimi Gönder` CTA.

---

## 5. Role Switcher & Profile Settings
- Accessible from the **Profil** tab or **Avatar**:
  - **Kullanıcı Rolü**: Toggle between `Site Sakini` (Ahmet Yılmaz) and `Site Yöneticisi` (Mehmet Demir).
  - **Parametrik Tema**: ☀️ Açık Tema / 🌙 Koyu Tema (applies instantly to both Sakin and Yönetici interfaces).
  - **Para Birimi**: Locked to `🇹🇷 Türk Lirası (₺)`.
