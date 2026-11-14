# Sakinler & Malikler: compact unit directory

Date: 14 November 2026

Status: proposed design for review; application implementation is outside this change

Companion: [mobile design preview](ux-reference/mobile_unit_directory_preview.html) · [responsive draft](ux-reference/compact_unit_directory.html)

## Recommendation

Use a mobile-first unit list with two explicit entries on every compact card: **İşlemler** for the action list and **Detay** for optional information. İşlemler opens the full-screen unit workspace directly on grouped, tappable actions. Details never have to be opened to reach the actions. Keep search, filters, sorting, page, scroll position and focus when returning. Desktop uses the same two entries in a table.

## Evidence and limits

This analysis inspects the application source carried by master at `3f0c8db`. No screenshot or running application session was supplied; current pixel heights, task times and production performance have not been measured. Proposed dimensions and success criteria below are design targets, not measured improvements. All people and records in the draft are fictional.

| Observed source | Finding | Design implication |
| --- | --- | --- |
| [Module page](../flutter/lib/ui/residents/owners_residents_module_page.dart) | Summary, search, occupancy chips and block chips precede the directory; every matching unit is expanded using `filtered.map`. | Reduce repeated content and build only visible/page items. Keep a short toolbar reachable while scrolling. |
| [Unit card](../flutter/lib/ui/residents/owners_residents_unit_card.dart) | Each card includes metadata, monthly dues, responsible-person spotlight, contact details, resident/owner tabs, household content and management actions. | Separate finding a unit from operating on it. Contact and lifecycle controls belong in detail. |
| [Fullscreen page](../flutter/lib/ui/components/app_fullscreen_page.dart) | Default content width is 640 px; full-screen navigation is established. | Explicitly widen the desktop directory; do not place a wide table inside the existing narrow container. Reuse full-screen navigation for detail. |
| [Directory helpers](../flutter/lib/ui/residents/resident_directory.dart) | Search already covers owner, tenant, responsible person, household names and contacts, unit and block. Occupancy and block filters already exist. | Preserve this search coverage. Show why a hidden household/contact result matched. |
| [Unit-state model](../flutter/lib/domain/models/unit_state.dart) and [EPIC-08](../.specify/requirements/EPIC-08-occupancy-lifecycle-and-dual-ledger-management.md) | Ownership and occupancy are independent; permitted commands depend on state. | Keep owner, occupant and primary contact distinct. Vacancy must never imply missing ownership. |

The primary failure is information density: the interface repeats the complete operational workspace before the manager has chosen a unit. A smaller font or a multicolumn card grid would still repeat the same controls and would make cross-unit comparison harder.

## Mobile navigation revision

The first draft placed a read-only action list after the details on phones. That made actions hard to discover and treated mobile as a narrower desktop page. This revision makes the action list a primary destination.

1. **Unit list:** compact identity, occupancy, resident and owner; two full-width-in-column, 48 px minimum targets: İşlemler and Detay. No hidden swipe gestures or icon-only overflow menu.
2. **İşlemler:** full-screen grouped action rows, approximately 72 px minimum height with a label and short explanation. Actions are grouped under Kişiler, İkamet, Mülkiyet, Daire and Diğer. Show only commands appropriate to the selected unit's state; validate authorization and eligibility in the real application. Destructive deletion is separated at the end.
3. **Optional details:** Detay opens the information view directly. Within the unit workspace, İşlemler / Daire bilgileri switches between actions and information. Resident, owner and history tabs belong only to the information view.
4. **Action destination:** tapping an action opens a full-screen preview. The design demonstrates navigation; it does not perform mutations or pretend to save. Daire tarihçesi opens the existing information tab in the draft.
5. **Thumb navigation:** a persistent bottom return button on unit, action and filter pages, plus a top back button. Browser Back/Forward navigates the same stack; returning restores focus and list position. Reserve space below content so the return bar cannot cover the last action, including at large text sizes.
6. **Search and filters:** keep search visible in the list. Filtrele opens a dedicated full-screen filter/sort page, with a bottom apply button and cancel/back behavior. Draft filter selections are applied only on confirmation. Applied-filter count remains visible on the list; clear resets search and filters. Global summary collapses to total units on phones to recover vertical space.

The phone layout intentionally spends a small amount of row height on clearly labeled actions. Legible touch targets and predictable navigation take precedence over matching desktop density.

## Core jobs

1. Find a unit by block and number, person or contact information.
2. Compare who lives in each unit, who owns it and who the manager should contact.
3. Review a subset, such as vacant units in block B.
4. Open the right unit, perform a permitted operation, and return to the same place.

## Proposed information hierarchy

### Directory

- Header: “Sakinler & Malikler”, site identity and a link to the existing registration flow. Keep people directory and house types available as secondary navigation.
- Compact summary: total units and occupied/vacant counts in one line. Avoid a large KPI card stack above the list.
- Toolbar: search and Filtrele on mobile; block select, occupancy select, sort and comfortable/compact density on desktop. Changing a filter resets to page 1. A visible clear-filters action also clears search.
- Result caption: “1–25 / 240 daire”. Label global summary separately from filtered result counts. Preserve the result count in an accessible live region.
- Desktop columns: unit, occupancy, current resident, owner, primary contact, separate İşlemler and Detay buttons. Unit number sorts numerically within naturally ordered blocks; stable unit ID breaks ties. Clicking the header may be added later; the draft uses an explicit sort control.
- Unit cell: strong block + number; floor and housing type as secondary text. Put full land share, telephone, email, household members, IBAN, history and financial ledgers in detail.
- Resident cell: tenant name when rented; owner-occupant name when owner occupied; “İkamet eden yok” when vacant. Missing owner becomes “Malik kaydı yok”, never a fabricated person. Missing unit assignment becomes “Daire atanmadı”. Multiple owners show first name + count, with all names in detail when supported by the directory projection.
- Primary contact cell: resolved responsible person's name and role. Do not infer it from the tenant flag. The same person may legitimately appear in several role columns.
- No financial total in the default directory. If later requested, add clearly separated operating/capital columns using existing Decimal formatters; monthly dues must not be relabeled as outstanding debt.

### Unit workspace: actions first, details optional

İşlemler opens the full-screen action list with unit identity and current resident/owner context. The initial screen contains the action list itself, rather than a detail panel with actions below it. Detay opens the separate information mode. Both modes share the same unit and back stack.

| Group | Action entries | Availability |
| --- | --- | --- |
| Kişiler | Edit resident, edit/register owner, add household member, select primary contact | Resident/household actions require an active occupancy; primary contact requires a recorded person. |
| İkamet | Tenant move-in, owner move-in, replace tenant, owner takes back, rent out, move-out | Apply the existing state matrix in EPIC-08 and server permission checks. |
| Mülkiyet | Title transfer | Requires an owner on record. |
| Daire | History, virtual IBAN | Existing read workflows; do not fabricate an IBAN or history in the draft. |
| Diğer | Delete unit | Separate destructive entry; real eligibility and explicit full-screen confirmation remain mandatory. |

On the information side, keep overview/residents/owners/history tabs. Production financials must retain separate operating/capital ledgers. The draft previews all action entries and navigation but does not implement real registration, changes, transfers, deletion, ledgers, bank details or history data. A narrow drawer or expanding every unit into a management form would recreate the density problem.

### Responsive behavior and accessibility

| Width | Presentation |
| --- | --- |
| 1200 px and wider | Full table, maximum content width around 1440 px; 56 px compact or 72 px comfortable row target. |
| 800–1199 px | Table without the primary-contact column; primary contact remains searchable and available in detail. |
| Under 800 px | Compact cards: unit/status, resident, owner, then separate 48 px İşlemler and Detay targets. Search stays on the list; filters open full-screen. No horizontal table scroll. |

Comfortable is the default; compact suits mouse/keyboard management. Text scaling may grow rows beyond their nominal height. Labels accompany status colors. Use semantic table headers, labeled controls, visible focus, keyboard-operable action/detail buttons and tabs, and restore focus to the originating row. Mobile detail and confirmation remain full-screen. Test at 200% text size and 320 px viewport width.

## Scale, state and edge cases

- Start with 25 rows per page; allow 50 and 100. Render page items lazily in Flutter. Pagination avoids an endless page and gives a stable return location. The draft uses 240 generated records to exercise this behavior.
- The current controller holds all units. Client-side filtering and pagination are a first delivery, not a claim of backend scalability. Before supporting very large sites, benchmark 1,000 and 10,000 records; consider a tenant-scoped server search/sort/page contract and counts. Do not silently change household search semantics during that move.
- Debounce a future remote search; cancel stale responses and preserve the latest input. Use Turkish-aware case folding, including I/İ/ı/i, and normalized phone matching. Sorting must use consistent locale-aware text comparison and numeric unit numbers.
- On return, retain query, block, occupancy, density, sort, page, scroll and focus. After a successful edit, refresh data and retain state; if the unit no longer matches, explain that and focus the nearest remaining row. Clamp page after result counts shrink. Initial-unit deep links must reveal and focus the requested record or explain unavailable access.
- Loading: short row skeletons. Empty site: explain how to register the first record. No matches: explain filters and offer reset. Load error: inline retry preserving filters. Missing contact: explicit text. Long names: allow wrap and provide complete text in detail. Hidden-field search: show a short match explanation, without exposing sensitive values unnecessarily.
- No bulk move-out, deletion or title transfer in the first design. Those need separate business requirements and safeguards.

## Alternatives considered

| Option | Assessment |
| --- | --- |
| Smaller existing cards | Quick cosmetic change, but repeated controls and eager rendering remain. |
| Collapsible cards | Better initial density, but expanded rows create uneven heights and a growing scroll burden. |
| Grid of unit tiles | Good occupancy overview; weak comparison of resident, owner and responsible person. Could be a separate future view. |
| Compact list + full-screen actions and optional details | Recommended: clear action discovery, comfortable touch targets and reuse of existing workflows. |

## Acceptance criteria for implementation

1. At a 1440×900 desktop viewport, target at least eight complete compact rows above the fold with the toolbar visible. Record the baseline first and compare actual rendered heights; do not claim a density multiplier before measuring.
2. At 320, 390, 768, 1024 and 1440 px, no page-level horizontal overflow or overlapping controls. At 200% text size, content remains reachable and legible.
3. Search finds owners, tenants, responsible people, household members and normalized contact values; combined filters and clear behavior are predictable.
4. Unit 2 sorts before 10. Switching filters resets pagination; changing density preserves query and page. Result counters are accurate for zero, one and many results.
5. Every mobile unit exposes separate İşlemler and Detay buttons. İşlemler opens actionable rows immediately, without opening details first. Filter cancel preserves applied settings; apply resets pagination. Browser Back/Forward and top/bottom return buttons restore the appropriate view, position and focus. Missing/stale/deep-linked units have explicit outcomes.
6. Vacant owned units retain their owner; unowned units do not show tenant move-in. State/permission checks, occupancy history, ledgers and destructive confirmations retain current behavior.
7. On an agreed reference device with 1,000 records, target local filter/sort updates below 200 ms; collect timings rather than infer performance from row height.
8. Observe managers completing find-person, identify-owner, filter-vacant and return-from-detail tasks against the current screen. Compare task time, mistakes and scrolling before accepting the redesign.

## Delivery plan

1. Review this draft and validate the column order with managers. Confirm whether primary contact or owner is the more frequent scanning target.
2. Implement a shared responsive directory row/table using existing theme, status, filter, empty-state and selection components; reuse `resident_directory.dart` and `AppFullscreenPage`. Preserve stable test IDs where possible; revise affected widget/E2E selectors deliberately.
3. Move existing card workflows into a dedicated unit workspace with actions as the default entry and information as an optional mode, without changing domain behavior. Keep registration, people and house-type entry points reachable.
4. Verify directory filtering, sorting, state restoration, keyboard navigation and occupancy workflows; run Flutter reuse, logging and applicable project gates. Benchmark before deciding on server pagination.

## Draft review guide

Open the companion HTML directly in a browser; it requires no server or network. Try searching “Deniz” (a household member), “İpek”, a unit number, or “DEMO-001”; combine block and occupancy filters; open İşlemler and tap an action preview; return using bottom navigation or browser Back; open Detay only when needed. At phone width, use Filtrele to apply or cancel filter and sort selections. Density remains a desktop control. Demo contact tokens intentionally avoid plausible real phone numbers and email addresses. No data is sent or persisted.

This is a design artifact, not a deployed application change. Browser verification and repository checks are reported in the accompanying PR.

## Draft verification

The revised standalone draft was exercised in touch-enabled headless Chrome at widths 320, 390, 430, 768, 800, 1024 and 1440 px with no page-level horizontal overflow. Interaction checks cover actions-first entry, optional direct details, grouped action previews, state-appropriate commands for tenant/owner/vacant/unowned units, browser Back/Forward, return focus, full-screen filter apply/cancel, household search, pagination and numeric ordering. Bottom navigation remains visible, and the final destructive entry can be scrolled above it. Dark mode and a large-text smoke check are included. These are draft checks, not Flutter implementation or real-device usability results.

The previous eight-row desktop density result belongs to the first version; the revised design prioritizes mobile action access. Current project gate results are recorded in the accompanying PR. Database and application GUI gates are explicitly skipped when unavailable, never counted as passed.
