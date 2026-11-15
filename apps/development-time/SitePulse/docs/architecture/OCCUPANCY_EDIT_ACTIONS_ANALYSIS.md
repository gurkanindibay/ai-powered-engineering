# Occupancy editing through unit actions

## Decision and problem

Existing units change occupancy through the dedicated unit workspace actions.
Resident details display the current occupancy and link people to person cards.
The status selector in `owners_residents_edit.dart` duplicated those actions and
submitted `removeTenant` and `isResident` through `updateHomeOwner` on Save.
It did not collect the same explicit command confirmation as the occupancy flows.

The backend legacy edit path already delegates tenant removal and creation to
`occupancy_repository::apply_occupancy_command`. Therefore it would be inaccurate
to claim that every selector change bypassed history or settlement. However,
selecting tenant on a vacant unit supplied no incoming person, and selecting owner
on a vacant unit supplied no explicit owner move-in command. The editor could not
reliably represent every transition it offered. Its widget test actually required
silent tenant removal when saving owner occupancy.

## Case inventory

| Starting state / intent | Existing action | Expected result |
| --- | --- | --- |
| Owned, vacant: tenant arrives | Tenant move-in | Tenant session opens; ownership remains |
| Owned, vacant: owner arrives | Owner move-in | Recorded owner selected; owner session opens |
| Owner occupied: owner leaves | Move-out | Vacant; ownership remains |
| Owner occupied: rent to tenant | Owner rents out | Owner session closes and tenant opens atomically |
| Tenant occupied: tenant leaves | Move-out | Vacant; tenancy closes with exit balance |
| Tenant occupied: new tenant | Replace tenant | Outgoing session settles; incoming session opens atomically |
| Tenant occupied: owner returns | Owner takes back | Tenant closes and recorded owner opens atomically |
| Vacant: title transfer | Title transfer | New ownership; unit stays vacant |
| Tenant occupied: sale to third person | Title transfer | Tenant and active occupancy remain |
| Tenant occupied: sale to current tenant | Title transfer | Tenant settles and becomes owner occupant |
| Owner occupied: sale | Title transfer | Old owner closes; vacant unless new owner moves in |
| Multiple owners: owner moves in | Owner move-in / takes back | Choose an owner already on record |
| No recorded owner | Register owner | Establish ownership before move-in |
| Legacy tenant without owner | Move-out | Permit exit; do not invent ownership |
| Change primary contact | Select contact | Occupancy and ownership unchanged |
| Add, edit, remove household member | Household action | Membership only; no primary occupancy change |
| Edit name, phone, email | Person card | Person identity changes through its own flow |
| Inspect or close resident/owner details | Details | No occupancy or ownership mutation |
| New registration | Initial occupancy selection | Create matching initial ownership and occupancy records |
| Cancel a transition | Back / cancel | No transition submitted |
| Stale state, invalid person, illegal command | Existing server validation | Reject without partial transition |

## Implementation

Remove the editable segmented selector and the generic Save button from resident
and owner details (both use `_openEditHomeOwner`). Show the effective occupancy in
`SpGuidanceCard` with instructions to return to unit actions. Keep Close, person
card navigation and the independent household actions. Render the tenant card
from the actual unit occupancy rather than a locally chosen mode.

The unit workspace already offers all six occupancy commands and title transfer
conditionally through `allowedOccupancyCommands`; no additional action is needed.
Initial registration remains an intentional exception for establishing state.
No database migration or retrospective rewriting of historical sessions is needed.
The legacy update API remains compatible; dedicated lifecycle commands remain the
required UI path. This change does not claim to remove that API compatibility.

## Requirements and verification

EPIC-08 §3.5 makes read-only details normative. SC-08-07-09 covers unchanged state
and continued access to lifecycle actions; SC-12-06-02 covers person card access.
Replace the former widget test that expected an implicit tenant-to-owner switch.
SC-08-07-10 covers owner-occupied and vacant owner details. Retain existing command matrix, lifecycle, registration and title-transfer tests.
Exercise owner-occupied, tenant-occupied and vacant details: no selector, no Save,
correct person cards and unchanged state on Close. The same details implementation
serves both owner and resident entry points.

Existing tools (`run_tests.py`, `feature_traceability.py`, Flutter tests) cover the
regression and case inventory. No new diagnostic CLI is needed.
