# SitePulse page layout standard

## Module pages

Every dashboard destination starts at the top of the content viewport. The application bar and
primary navigation remain in the dashboard shell. Content uses the shared 1200 dp maximum width,
16 dp mobile gutters, 24 dp wide-screen gutters, and 16 dp gaps around headers.

Use this sequence:

1. Context navigation (the manager / own-flat switcher), owned by the dashboard shell.
2. `SpPageHeader`: one bordered surface containing the page title, decorative icon, optional
   site/context subtitle and wrapping page actions. Use the same header in populated, loading
   and empty states. Do not truncate the title or place it in a KPI card.
3. Section navigation, where applicable. It precedes the summary so changing sections does not
   require reading or scrolling past metrics. Dues section tabs wrap on compact widths.
4. Period selection and summary metrics.
5. Search and filters, followed by results, loading placeholders or guidance.

Use theme surfaces, border colours, `AppSpacing` and `AppRadius`. Preserve automation identifiers.
Actions and text must remain usable at 320 dp and 200% text scale in light and dark themes.

## Full-screen flows

`AppFullscreenPage` supplies the page identity through its top AppBar with back navigation, title
and optional subtitle. Its body is horizontally constrained and aligned to the top, in both
scrollable and non-scrollable modes. Forms and detail flows keep their existing content widths
(640 dp by default); complex directories retain their explicit wider limits. Commit and cancel
controls remain in the sticky bottom bar. Do not add a duplicate body title card to these flows.

## Screen audit and application

| Screen family | Finding | Standard applied |
| --- | --- | --- |
| Manager cockpit | Custom site banner mixed identity and counts | Shared module header; site switch action retained |
| Dues and collections | Unboxed title; section tabs below summary; missing context switcher | Shared header and actions; tabs before summary; shell context switcher |
| Owners and residents dashboard | Custom header; fullscreen action competed with title | Shared header with wrapping actions and preserved automation ids |
| Resident / owner home | Balance card acted as page identity | Shared identity header before balance and household content |
| Household dashboard | Unboxed heading with path-specific duplication | Shared header, shell owns context switcher |
| Platform administration | Identity embedded in global metrics | Shared header before global metrics |
| Auditor finance desk | Started directly with section filters | Shared identity header before finance navigation |
| Finance hub, budget, statements and payment tracking | Shared full-screen AppBar | Retained AppBar and bottom actions; top-aligned body through shared host |
| People directory, profiles, imports, preferences, owners module | Shared full-screen AppBar | Same shared host correction, no duplicate body title |
| Announcements, security, reconciliation, assignment and confirmation flows | Shared full-screen host | Same top alignment and body gutters |
| Login, account linking, forced password change | Authentication tasks outside dashboard navigation | Retain focused authentication layouts; no manager tabs |

The static UX prototypes are reference artifacts; this standard is implemented in the Flutter
application. Component coverage lives in `reusable_components_test.dart`, including both themes,
mobile and desktop widths, enlarged text, action callbacks and short full-screen content.
`page_layout_test.dart` checks navigation between populated manager modules at 320, 390 and
1400 dp: context/header position, boxed identity, section order and absence of overflow.
