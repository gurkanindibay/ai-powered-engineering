# Sakinler & Malikler: compact unit directory

Date: 14 November 2026

Status: proposed design for review; application implementation is outside this change

Companion: [interactive design draft](ux-reference/compact_unit_directory.html)

## Recommendation

Replace the repeated expanded unit cards with a compact directory. Show one scan-friendly row per unit, then open a dedicated full-screen unit page for contact details and management. Keep search, filters, sorting, page and scroll position when returning. On phones, use short stacked rows rather than squeezing a desktop table into the viewport.

## Evidence and limits

This analysis inspects the current source on master at `4320ca2`. No screenshot or running application session was supplied; current pixel heights, task times and production performance have not been measured. Proposed dimensions and success criteria below are design targets, not measured improvements. All people and records in the draft are fictional.

| Observed source | Finding | Design implication |
| --- | --- | --- |
| [Module page](../flutter/lib/ui/residents/owners_residents_module_page.dart) | Summary, search, occupancy chips and block chips precede the directory; every matching unit is expanded using `filtered.map`. | Reduce repeated content and build only visible/page items. Keep a short toolbar reachable while scrolling. |
| [Unit card](../flutter/lib/ui/residents/owners_residents_unit_card.dart) | Each card includes metadata, monthly dues, responsible-person spotlight, contact details, resident/owner tabs, household content and management actions. | Separate finding a unit from operating on it. Contact and lifecycle controls belong in detail. |
| [Fullscreen page](../flutter/lib/ui/components/app_fullscreen_page.dart) | Default content width is 640 px; full-screen navigation is established. | Explicitly widen the desktop directory; do not place a wide table inside the existing narrow container. Reuse full-screen navigation for detail. |
| [Directory helpers](../flutter/lib/ui/residents/resident_directory.dart) | Search already covers owner, tenant, responsible person, household names and contacts, unit and block. Occupancy and block filters already exist. | Preserve this search coverage. Show why a hidden household/contact result matched. |
| [Unit-state model](../flutter/lib/domain/models/unit_state.dart) and [EPIC-08](../.specify/requirements/EPIC-08-occupancy-lifecycle-and-dual-ledger-management.md) | Ownership and occupancy are independent; permitted commands depend on state. | Keep owner, occupant and primary contact distinct. Vacancy must never imply missing ownership. |

The primary failure is information density: the interface repeats the complete operational workspace before the manager has chosen a unit. A smaller font or a multicolumn card grid would still repeat the same controls and would make cross-unit comparison harder.

## Core jobs

1. Find a unit by block and number, person or contact information.
2. Compare who lives in each unit, who owns it and who the manager should contact.
3. Review a subset, such as vacant units in block B.
4. Open the right unit, perform a permitted operation, and return to the same place.

## Proposed information hierarchy

### Directory

- Header: “Sakinler & Malikler”, site identity and a link to the existing registration flow. Keep people directory and house types available as secondary navigation.
- Compact summary: total units and occupied/vacant counts in one line. Avoid a large KPI card stack above the list.
- Toolbar: search; block select; occupancy select; sort; comfortable/compact density. Changing a filter resets to page 1. A visible clear-filters action also clears search.
- Result caption: “1–25 / 240 daire”. Label global summary separately from filtered result counts. Preserve the result count in an accessible live region.
- Desktop columns: unit, occupancy, current resident, owner, primary contact, open detail. Unit number sorts numerically within naturally ordered blocks; stable unit ID breaks ties. Clicking the header may be added later; the draft uses an explicit sort control.
- Unit cell: strong block + number; floor and housing type as secondary text. Put full land share, telephone, email, household members, IBAN, history and financial ledgers in detail.
- Resident cell: tenant name when rented; owner-occupant name when owner occupied; “İkamet eden yok” when vacant. Missing owner becomes “Malik kaydı yok”, never a fabricated person. Missing unit assignment becomes “Daire atanmadı”. Multiple owners show first name + count, with all names in detail when supported by the directory projection.
- Primary contact cell: resolved responsible person's name and role. Do not infer it from the tenant flag. The same person may legitimately appear in several role columns.
- No financial total in the default directory. If later requested, add clearly separated operating/capital columns using existing Decimal formatters; monthly dues must not be relabeled as outstanding debt.

### Unit detail

Open a full-screen page at every breakpoint, with a clear back action, unit identity and occupancy. Use tabs for overview, residents, owners, financials and history in production. Keep routine edit/contact actions with their section. Show move-in, move-out, tenant replacement, title transfer and deletion only in the relevant detail workflow, governed by permissions and allowed commands; retain existing confirmations and audit history. A narrow drawer or expanding all rows would recreate the density problem and conflict with mobile navigation rules.

The review draft includes overview/residents/owners/history tabs and a read-only list of state-appropriate operations. Registration, mutations, ledgers, IBAN and actual history records are intentionally not simulated as functioning business workflows. They must reconnect to existing application flows during implementation.

### Responsive behavior and accessibility

| Width | Presentation |
| --- | --- |
| 1200 px and wider | Full table, maximum content width around 1440 px; 56 px compact or 72 px comfortable row target. |
| 800–1199 px | Table without the primary-contact column; primary contact remains searchable and available in detail. |
| Under 800 px | Two-to-three-line unit rows: unit/status, resident, owner; one 44 px minimum detail target. Toolbar wraps; no horizontal table scroll. |

Comfortable is the default; compact suits mouse/keyboard management. Text scaling may grow rows beyond their nominal height. Labels accompany status colors. Use semantic table headers, labeled controls, visible focus, keyboard-operable detail buttons and tabs, and restore focus to the originating row. Mobile detail and confirmation remain full-screen. Test at 200% text size and 320 px viewport width.

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
| Compact directory + full-screen detail | Recommended: stable comparison, predictable height and reuse of existing workflows. |

## Acceptance criteria for implementation

1. At a 1440×900 desktop viewport, target at least eight complete compact rows above the fold with the toolbar visible. Record the baseline first and compare actual rendered heights; do not claim a density multiplier before measuring.
2. At 320, 390, 768, 1024 and 1440 px, no page-level horizontal overflow or overlapping controls. At 200% text size, content remains reachable and legible.
3. Search finds owners, tenants, responsible people, household members and normalized contact values; combined filters and clear behavior are predictable.
4. Unit 2 sorts before 10. Switching filters resets pagination; changing density preserves query and page. Result counters are accurate for zero, one and many results.
5. Opening a unit and returning restores list state, position and keyboard focus. Missing/stale/deep-linked units have explicit outcomes.
6. Vacant owned units retain their owner; unowned units do not show tenant move-in. State/permission checks, occupancy history, ledgers and destructive confirmations retain current behavior.
7. On an agreed reference device with 1,000 records, target local filter/sort updates below 200 ms; collect timings rather than infer performance from row height.
8. Observe managers completing find-person, identify-owner, filter-vacant and return-from-detail tasks against the current screen. Compare task time, mistakes and scrolling before accepting the redesign.

## Delivery plan

1. Review this draft and validate the column order with managers. Confirm whether primary contact or owner is the more frequent scanning target.
2. Implement a shared responsive directory row/table using existing theme, status, filter, empty-state and selection components; reuse `resident_directory.dart` and `AppFullscreenPage`. Preserve stable test IDs where possible; revise affected widget/E2E selectors deliberately.
3. Move existing card content into a dedicated unit-detail page without changing domain behavior. Keep registration, people and house-type entry points reachable.
4. Verify directory filtering, sorting, state restoration, keyboard navigation and occupancy workflows; run Flutter reuse, logging and applicable project gates. Benchmark before deciding on server pagination.

## Draft review guide

Open the companion HTML directly in a browser; it requires no server or network. Try searching “Deniz” (a household member), “İpek”, a unit number, or “DEMO-001”; combine block and occupancy filters; change density and page size; open a unit and return. Resize to a phone width. Demo contact tokens intentionally avoid plausible real phone numbers and email addresses. No data is sent or persisted.

This is a design artifact, not a deployed application change. Browser verification and repository checks are reported in the accompanying PR.

## Draft verification

The standalone draft was exercised in headless Chrome at widths 320, 390, 768, 800, 1024 and 1440 px with no page-level horizontal overflow. At 1440×900, compact mode displayed eight complete rows above the fold, including the review-only banner. This measures the draft only, not the current Flutter page or a production improvement ratio.

Interaction checks passed for numeric unit ordering, Turkish-case search, household and demo-contact matches, combined block/occupancy filters, zero-result reset, page size, pagination, unit detail, keyboard tab navigation and return focus/page retention. A separate example makes a household member the primary contact, independently of resident and owner. Dark mode and a large-text smoke check passed; assistive-technology and real-device usability review remain necessary. No browser script errors were observed.

All 91 harness tests and all 15 gates executed by `python3 apps/development-time/SitePulse/scripts/run_tests.py --skip-db --skip-gui --summary` passed. Schema integrity, Rust database tests, API system checks and application GUI E2E were explicitly skipped, not counted as passed. The standalone browser checks above cover the design draft; they do not replace application E2E. The local Graphify code graph was refreshed; its SQL extraction reported a missing optional `tree_sitter_sql` dependency.
