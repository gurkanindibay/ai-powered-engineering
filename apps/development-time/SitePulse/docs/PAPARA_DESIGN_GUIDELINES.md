# Papara Design Guidelines & Principles
## SitePulse Residential Management Platform Design System

> **Source of Truth:** Analyzed directly from official Papara mobile application interfaces (Dashboard, Money Transfer, Card Showcase, Cashback Program, and Portfolio screens).  
> **Platform Scope:** Mobile (Flutter / Material 3) & Desktop/Mobile Web Prototypes.  
> **Target Aesthetic:** High-End Fintech • Ultra-Clean Light Canvas • Deep Jet Black Accents • Crisp Contrast • Zero Visual Clutter.

---

## 1. Core Visual Principles & Philosophy

```
┌────────────────────────────────────────────────────────────────────────┐
│                      PAPARA DESIGN PHILOSOPHY                          │
│                                                                        │
│   1. Ultra-Clean Canvas       2. Pure Black & Crisp White Contrast     │
│   3. Razor-Thin Borders (1px) 4. Soft Micro-Elevation (4px blur)       │
│   5. Circular Story Actions   6. Authoritative Financial Typography    │
└────────────────────────────────────────────────────────────────────────┘
```

1. **Light & Crisp First (The Pure Canvas)**:
   - Papara's primary identity is an immaculate, high-contrast, pure-white card surface (`#FFFFFF`) sitting on a calm, subtle off-white canvas (`#F8F9FA`).
   - High legibility is prioritized over decorative backgrounds: zero heavy neon glows, zero harsh drop shadows, zero chromatic aberration.

2. **Black & White Dominance with Intentional Semantic Color**:
   - **Solid Jet Black (`#0B0F19` / `#111827`)** is the primary brand and action anchor. Used for primary CTA buttons, active tabs, active filter capsules, and active navigation indicators.
   - Colors are strictly functional and reserved for financial states:
     - **Emerald Green (`#10B981`)**: Income, cashback, positive balances, successful transaction verification.
     - **Coral Crimson (`#EF4444`)**: Unread notification badges, overdue debt alerts, negative balances.
     - **Muted Bank/Brand Accents (`#2563EB`, `#F59E0B`)**: Reserved strictly for quick-contact avatar badges and category chips.

3. **Curved Geometry Scale**:
   - **Hero Account & Action Cards**: `20px` radius.
   - **Input Fields & Bottom Sheets**: `12px` to `16px` radius.
   - **Story & Contact Badges**: `50%` (Perfect Circle).
   - **Filter Chips & Action Pills**: `9999px` (Full Capsule).

---

## 2. Color Palette & Design Tokens

### 2.1 Dual-Theme Core Palette (Light & Dark Black/White)

| Token | Light Theme Value | Dark (Black/White) Value | Usage in Papara Architecture |
| :--- | :--- | :--- | :--- |
| `paparaCanvas` | `#F8F9FA` | `#121317` (Matte Obsidian) | Root scaffold background canvas |
| `paparaSurface` | `#FFFFFF` | `#1C1D24` (Dark Graphite) | Primary cards, modal dialogs, bottom sheets |
| `paparaCardStacked` | `#F1F3F5` | `#181920` | Stacked card depth underneath notice cards |
| `paparaBorder` | `#E5E7EB` | `#282A33` | 1.0px razor structural borders, card outlines |
| `paparaTextPrimary` | `#0B0F19` | `#FFFFFF` | Hero balances, screen titles, primary headers |
| `paparaTextSecondary`| `#6B7280` | `#8E9297` | Subtitles, account numbers, timestamps |
| `paparaTextMuted` | `#9CA3AF` | `#63676E` | Micro captions, inactive labels, placeholders |
| `paparaActionPrimary`| `#0B0F19` | `#FFFFFF` | Primary pill button fill or contrast text |
| `paparaWithdrawRed` | `#EF4444` | `#E53935` | Negative action: `[-] Çek` / `Aidat Öde` circular button |
| `paparaDepositGreen` | `#10B981` | `#43A047` | Positive action: `[+] Yatır` circular button, `+₺` transfers |
| `paparaBadgeRed` | `#EF4444` | `#E53935` | Notification counter badges (`1`, `2`), campaign pills |

### 2.2 Papara Black & White (Dark Mode) Architectural Patterns

```
┌────────────────────────────────────────────────────────┐
│  [ ☰ ]                    p                    (Avatar)│
│                                                Hesabım │
│                                                        │
│     ( 🎁 ₺45 )          ( Türk Lirası 🇹🇷 TL ⌵ )        │
│                                                        │
│        (-)                 ₺1,38                 (+)   │
│        Çek                                      Yatır  │
│                   Papara Numaran: 10147XXXXX           │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │ 08 Şubat 2023 11:04                              │  │
│  │ Dayanışma zamanı 🤝                              │  │
│  │ Deprem bölgesindeki sivil toplum kuruluşları...  │  │
│  └──────────────────────────────────────────────────┘  │
│  ════════════════════════════════════════════════════  │ (Stacked card)
│                                                        │
│  SON İŞLEMLER →                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │ (Avatar)  Turgut Efe Küçük               +₺0,08  │  │
│  │           Gelen Transfer       07 Şubat 08:49    │  │
│  │           💬 Al hadi al yengemi yemeğe götür...  │  │
│  └──────────────────────────────────────────────────┘  │
│                                                        │
│  CASHBACK →                                            │
│  ┌──────────────────────────────────────────────────┐  │
│  │ [Dizi %50]  (N) Netflix                          │  │
│  │                 Her ay ₺32 kazan                 │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────┘
```

#### Key Black & White Principles:
1. **Floating Hero Balance without Card Border**:
   - In Dark Mode, the hero balance (`₺1,38` or `₺1.423,33`) floats directly on the matte obsidian canvas (`#121317`) in massive bold pure white typography (`40-44px ExtraBold`).
   - Flanked directly on the left and right by circular action buttons:
     - **Left `[-]` (Red `#E53935`)**: Withdraw / Pay (`Çek` / `Aidat Öde`).
     - **Right `[+]` (Green `#43A047`)**: Deposit / Top-up (`Yatır`).
   - Account / Papara / Flat number is centered below the amount in subtle `#8E9297`.

2. **Top Utility Capsules**:
   - Small rounded dark pills (`#1C1D24` background with `#282A33` border):
     - Quick bonus badge (e.g. `🎁 ₺45`).
     - Account currency selector dropdown (e.g. `Türk Lirası 🇹🇷 TL ⌵` or `SitePulse Dairem A-14 ⌵`).

3. **Pinned Announcement Card with Stacked Elevation**:
   - High-contrast dark container (`#1C1D24`, `border-radius: 16px`, `border: 1px solid #282A33`).
   - Stacked card edge visible below to indicate active carousel of announcements.
   - Micro date (`11px` `#8E9297`), bold title (`15px` `#FFFFFF`), and body snippet (`13px` `#9E9E9E`).

4. **Uppercase Navigation Micro-Headers with Chevrons**:
   - `SON İŞLEMLER →` and `CASHBACK →` in bold uppercase gray tracking (`#8E9297`).

5. **Chat / Transfer Message Snippets**:
   - Transaction list items include a preview note with speech bubble icon `💬` below the transaction type, rendering user remarks in `#8E9297`.

### 2.3 Elevation & Shadows
- **Card Soft Elevation**: `box-shadow: 0 4px 20px rgba(0, 0, 0, 0.03);`
- **Dropdown / Action Sheet Shadow**: `box-shadow: 0 10px 30px rgba(0, 0, 0, 0.08);`
- **Floating Button Shadow**: `box-shadow: 0 4px 12px rgba(11, 15, 25, 0.12);`

---

## 3. Typography Hierarchy

| Level | Size | Weight | Line Height | Example Content |
| :--- | :--- | :--- | :--- | :--- |
| **Hero Balance** | `32px - 34px` | ExtraBold (800) | `1.1` | `₺27.870,45` / `₺1.423,33` |
| **Screen Title** | `20px - 22px` | Bold (700) | `1.2` | `Para Gönder`, `Cashback` |
| **Section Header** | `11px - 12px` | Bold (700) | `1.3` | `SOHBET →`, `HESAP HAREKETLERİ →` (Uppercase + Letter Spacing 0.5px) |
| **Card Title / Name** | `15px - 16px` | SemiBold (600) | `1.3` | `Deniz Korkmaz`, `Türk Lirası Hesabı` |
| **Body / Description**| `13px - 14px` | Regular (400) | `1.4` | `Faturaları ben ödedim, haberin olsun.` |
| **Micro Caption / IBAN**| `11px - 12px` | Medium (500) | `1.2` | `IBAN'ın: TR52 0082...`, `Bugün, 19:30` |

---

## 4. Architectural Component Specifications

### 4.1 Top App Bar & Profile Module
```
┌────────────────────────────────────────────────────────┐
│  [ ☰ ]¹   [ 💬 ]²                Duru Demir            │
│                            Papara No: 6696710622   (O) │
└────────────────────────────────────────────────────────┘
```
- **Left Action Buttons**:
  - Two `40x40dp` rounded squircle buttons (`border-radius: 12px`, `#F3F4F6` background).
  - Menu icon (`☰`) with red notification badge (`#EF4444`, `16x16dp` circle, white text `1`).
  - Chat icon (`💬`) with red notification badge (`2`).
- **Right Profile Stack**:
  - Top line: User full name (`14px`, SemiBold `#0B0F19`).
  - Bottom line: Account identifier (`Papara No: 6696710622` or `Daire No: Blok A / No 14`), `11px` subtle gray, underlined clickable link.
  - Avatar: `38x38dp` circular photo container with 1px border `#E5E7EB`.

---

### 4.2 Quick Action "Story" Row (Circular Carousel)
```
  ╭───╮        ╭───╮        ╭───╮        ╭───╮        ╭───╮
  │ ★ │        │ 💬│        │ 🎁│        │ ☵ │        │ ✈ │
  ╰───╯        ╰───╯        ╰───╯        ╰───╯        ╰───╯
 Cashback    Sohbetler   Davet Et,     Kıymetli    Yurt Dışı
                           Kazan       Madenler  Para Transferi
```
- **Container**: `56x56dp` circle (`border-radius: 50%`), pure white background, 1.5px border `#E5E7EB`.
- **Icon Artwork**: Clean, thin 2px line illustration with subtle pastel accent.
- **Label**: `11px` medium weight `#374151`, centered, 2-line wrapped, max-width `68dp`.

---

### 4.3 Hero Financial Card (Swipeable Account Carousel)
```
┌────────────────────────────────────────────────────────┐
│  🇹🇷  Türk Lirası Hesabı                                │
│                                                        │
│  ₺27.870,45                                            │
│  IBAN'ın: TR52 0082 9000 0949 1234 5678 90             │
│                                                        │
│  ┌───────────────────────┐  ┌───────────────────────┐  │
│  │ 💳  Yatır / Çek       │  │  Gönder            ✈  │  │
│  └───────────────────────┘  └───────────────────────┘  │
└────────────────────────────────────────────────────────┘
                       ● ○ ○ ○ ○ ○
```
- **Card Surface**:
  - Pure white background (`#FFFFFF`), `20px` border radius, `1px solid #ECEFF1` border.
  - Soft shadow: `0 4px 16px rgba(0, 0, 0, 0.04)`.
  - Internal padding: `20dp`.
- **Card Elements**:
  - Currency badge: `18x18dp` circular flag/icon + `13px` medium text `#6B7280` ("Türk Lirası Hesabı" or "SitePulse Aidat Hesabı").
  - Large Bold Amount: `32px` ExtraBold tabular numbers (`₺27.870,45` or `₺1.423,33`).
  - Account/IBAN Subtitle: `12px` font `#6B7280` with underlined clickable link.
- **Dual In-Card Action Buttons**:
  - **Left Button (Secondary Action - "Yatır / Çek" or "Detay / Makbuz")**:
    - White background, `1px solid #E5E7EB`, `12px` radius.
    - Icon on left, `13px` SemiBold `#0B0F19`.
  - **Right Button (Primary Action - "Gönder" or "Hemen Öde")**:
    - Solid Jet Black (`#0B0F19`), `12px` radius.
    - Text: `13px` SemiBold `#FFFFFF`, paper plane / card icon on right.
- **Carousel Pagination**:
  - `6dp` circle dots centered `12dp` below the card.
  - Active dot: Solid black (`#0B0F19`), elongated pill or solid dot.
  - Inactive dots: `#D1D5DB`.

---

### 4.4 Feed & Activity List Pattern (With Uppercase Micro-Headers)
```
 SOHBET →
┌────────────────────────────────────────────────────────┐
│  (Avatar)  Deniz Korkmaz                  Bugün, 19:30 │
│            Faturaları ben ödedim, haber...         [2] │
└────────────────────────────────────────────────────────┘

 HESAP HAREKETLERİ →
┌────────────────────────────────────────────────────────┐
│  (Avatar)  Nehir Demir                        +₺19,93  │
│            Para Transferi • Papara ile... Bugün, 19:30 │
└────────────────────────────────────────────────────────┘
```
- **Section Micro-Header**:
  - `11px - 12px`, Bold, uppercase (`letter-spacing: 0.5px`).
  - Text color: `#6B7280` with trailing chevron arrow (`→`).
- **Activity Item Card**:
  - Pure white rounded card (`border-radius: 16px`, `border: 1px solid #E5E7EB`).
  - Left: `40x40dp` circular avatar or soft-tinted icon container.
  - Middle: Primary title (`14px` SemiBold `#0B0F19`) + Subtitle (`12px` Regular `#6B7280`).
  - Right:
    - Amount: `14px` ExtraBold (Green `#10B981` for positive `+₺`, Black `#0B0F19` for negative `-₺`).
    - Timestamp: `11px` Regular `#9CA3AF`.

---

### 4.5 Money Transfer & FAST Form Pattern
```
┌────────────────────────────────────────────────────────┐
│  <  Para Gönder                                    ⓘ   │
├────────────────────────────────────────────────────────┤
│        Cep Numarası       |   Papara No / IBAN         │
│                           |   ────────────────         │
├────────────────────────────────────────────────────────┤
│  Hızlı İşlemler                          Ekle/Düzenle  │
│    (Garanti)    (YapıKredi)    (Vakıf)                 │
│      Kızım        Demir         Duru                   │
├────────────────────────────────────────────────────────┤
│  [ Papara No / IBAN ]        ( Kolay Adres )           │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Papara Numarası ya da IBAN                    📷 │  │
│  └──────────────────────────────────────────────────┘  │
├────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────┐  │
│  │                    Devam Et                      │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────┘
```
- **Header**: Navigation back arrow (`<`), centered title (`17px` Bold), info button (`ⓘ`).
- **Top Segmented Tabs**: Text tabs with active black underline bar (`height: 2px`).
- **Quick Recipients ("Hızlı İşlemler")**: Circular contact avatars with embedded mini bank logo badges on the bottom-right.
- **Secondary Capsule Switcher**: Solid black active capsule vs white inactive capsule.
- **Input Field**: `14px` radius, `1.5px solid #E5E7EB` border, camera/QR scanner shortcut icon on right.
- **Full-Width Bottom CTA**: `16px` radius, fixed at the bottom with safe-area padding.

---

### 4.6 Gamified Cashback & Progress Metric Pattern
```
┌────────────────────────────────────────────────────────┐
│  Bu ay kazandığın               Bu ay kazanabileceğin  │
│  ₺50,00                         ₺960,00                │
│  ───────────[ P ]───────────────────────────────────── │
│             Bugüne dek toplam kazancın: ₺3.450,00      │
└────────────────────────────────────────────────────────┘
  [ (P) Tümü ]    [ ♡ Sana Özel ]    [ ✦ Online Alışveriş ]
```
- **Progress Gauge**: Clean horizontal line with branded thumb indicator `[ P ]`.
- **Pill Filters**:
  - Active: Solid black capsule (`#0B0F19`), white text.
  - Inactive: White capsule, colored outline, colored icon, dark text.
- **Cashback Card Item**: Rounded card with brand imagery, category badge (`Yeme & İçme %5`), logo, and reward calculation (`₺50 kazan`).

---

### 4.7 Bottom Navigation Bar
```
┌────────────────────────────────────────────────────────┐
│   ⌂          ▣           ➤           ☰           💳    │
│ Ana Sayfa   QR İşlem  Para Transfer  Ödemeler  Papara Card│
└────────────────────────────────────────────────────────┘
```
- **Canvas**: Pure white background (`#FFFFFF`), `height: 64dp` + bottom safe area.
- **Top Divider**: Razor-thin `1.0px solid #E5E7EB`.
- **5 Icon Slots**:
  1. `Ana Sayfa` (Home outline) — Active: Solid Black `#0B0F19`.
  2. `QR İşlemleri` (Scan/Grid icon).
  3. `Para Transferi` (Paper plane icon).
  4. `Ödemeler` (Receipt/bill icon).
  5. `Papara Card` (Card icon).
- **Text Label**: `10px - 11px`, Medium. Active is `#0B0F19`, Inactive is `#94A3B8`.

---

## 5. SitePulse Residential Translation Matrix

How Papara's fintech patterns map directly to SitePulse's residential management features:

| Papara Pattern | SitePulse Residential Equivalent | Functional Purpose |
| :--- | :--- | :--- |
| **"Türk Lirası Hesabı" Card** | **"SitePulse Aidat & Bakiye" Card** | Shows total dues, overdue penalties (KMK %5), and quick pay button |
| **"Yatır / Çek" Button** | **"Detay / KMK Makbuz" Button** | Opens statutory dues calculation breakdown modal |
| **"Gönder" Action Button** | **"Aidat Öde" Action Button** | Launches 3D Secure payment gateway / FAST transfer |
| **"Hızlı İşlemler" Contacts** | **"Sık Kullanılan İşlemler"** | Quick access: Dues Pay, Virtual IBAN, Receipts, Household Invite |
| **"Papara No / IBAN" Input** | **"Daireye Özel Sanal IBAN"** | Unit-specific deterministic IBAN with 1-tap copy and FAST badge |
| **"Cashback" Metric Slider** | **"Aylık Tahsilat İlerlemesi"** | Shows Site Manager collection rate (e.g. 76% paid, overdue list) |
| **"SOHBET" Card** | **"YÖNETİM DUYURULARI" Feed** | Broadcast notices (water outage, elevator maintenance, general assembly) |
| **"HESAP HAREKETLERİ" Feed** | **"AİDAT & MAKBUZ HAREKETLERİ"** | Real-time immutable fiscal audit ledger with green `+₺` and black `-₺` |

---

## 6. Implementation Checklist for Developers

- [x] Use **pure white (`#FFFFFF`)** cards on **soft off-white (`#F8F9FA`)** canvas.
- [x] Use **Solid Jet Black (`#0B0F19`)** for primary action pills and active navigation states.
- [x] Use **Emerald Green (`#10B981`)** strictly for positive financial events (`+₺`, paid status).
- [x] Use **Coral Crimson (`#EF4444`)** for overdue debt warnings and unread counter badges.
- [x] Zero neon colors (no `#00D2FF`, `#00E5A3`, `#FF4B72` glowing shadows).
- [x] Card corner radius: `20px`; Button radius: `12px - 16px`; Badges: `50%` circle.
- [x] All typography must be English in code, cleanly formatted with Turkish Lira (`₺`) currency symbols.
- [x] All financial calculations must use high-precision decimals (`Decimal` / `rust_decimal`).
