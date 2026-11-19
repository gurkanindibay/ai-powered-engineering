@EPIC-13 @STORY-13-10
Feature: Tenant data isolation across sites and resident accounts
  Use synthetic fixtures with distinct record IDs, people, amounts and references. Include
  the same visible unit labels in both sites to detect lookups that omit site scope.
  Use the same requests under authorized accounts as positive controls.

  @SC-13-10-01 @J-17 @layer:backend @core @role_manager @pending
  Scenario Outline: Manager lists, searches and aggregates use the authenticated site
    Given site A is in state F4 and site B is in state F5 with the same unit labels
    And each site has distinct people, payment references and IDs
    When each manager reads "<surface>" with its supported filters and pagination
    Then every returned record, total and count belongs to that manager's site
    And where the surface supports filtering on a foreign-only marker, that filter returns zero matches
    And the unfiltered read contains the manager's own seeded records

    Examples:
      | surface           |
      | unit directory    |
      | person search     |
      | payment stream    |
      | collection report |

  @SC-13-10-02 @J-17 @layer:backend @core @role_manager @pending
  Scenario Outline: Direct reads and downloads require access to the requested site
    Given both sites have an existing "<resource>" with different IDs and recognizable data
    And each site manager can retrieve that site's own resource
    When each manager makes the same request for the other site's resource ID
    Then the response is 403 or 404 and includes no foreign identifiers, amounts or personal data
    And no document bytes or download link for the other site are returned

    Examples:
      | resource                |
      | person card             |
      | billing period summary  |
      | receipt JSON            |
      | receipt PDF             |
      | operating budget        |

  @SC-13-10-03 @J-17 @layer:backend @core @role_manager @pending
  Scenario: A site parameter cannot widen a manager's collection or export permissions
    Given site A is in state F4 and site B is in state F5 with different synthetic people
    When the manager of site A requests a payment stream and a people export with the site B selector
    Then each endpoint either rejects the selector or returns only site A data
    And no foreign names, identifiers, amounts or counts appear in the response or export
    And site B's authorized manager can read the expected site B stream and export

  @SC-13-10-04 @J-17 @layer:backend @core @role_manager @pending
  Scenario Outline: A manager cannot mutate another site's records
    Given both sites have a resource eligible for "<action>"
    When the manager of site A attempts "<action>" using site B's resource ID
    Then the change is denied with 403 or 404
    And the target resource, business history, ledgers and pending requests in both sites are unchanged
    When the manager of site B performs the equivalent action on the authorized resource
    Then precisely the expected site B change is committed

    Examples:
      | action                |
      | record a payment      |
      | move out a tenant     |
      | close a billing period |

  @SC-13-10-05 @J-17 @state:F4 @layer:backend @core @role_resident @pending
  Scenario Outline: A resident cannot read another unit's financial records
    Given "Selin Demir" rents "A-2" and can read her own statement and receipt
    And "<target>" has a distinct statement and receipt accessible to its own resident
    When Selin requests that unit's statement and receipt JSON and PDF using their fixture IDs
    Then each request is denied with 403 or 404
    And none of the other unit's financial amounts, identifiers or documents appear

    Examples:
      | target                     |
      | A-5 at Selin's site        |
      | A-2 at a different site    |

  @SC-13-10-06 @J-17 @state:F2 @layer:backend @core @role_resident @pending
  Scenario: A tenant statement excludes the owner's private transactions for the same unit
    Given the tenant of "A-2" owes 1500.00 operational principal and has an issued receipt for an earlier payment
    And the owner has a 1000.00 capital liability and a separate private receipt for the same unit
    When the tenant opens their statement and their own receipt
    Then the tenant's operational debt and own receipt are visible
    And the owner's balance, payment movements and private receipt are absent from the statement
    When the tenant requests the owner's private receipt JSON and PDF by ID
    Then both requests are denied without returning the owner's payment data
    And the owner can retrieve their own receipt

  @SC-13-10-07 @J-17 @state:F6 @layer:backend @core @role_resident @pending
  Scenario: Replacing a tenant keeps each occupant's history and receipts private
    Given "Selin Demir" and "Mert Kılıç" have separate payments and private receipts for their respective occupancy of "A-2"
    And each tenant signed in before the replacement or at their first eligible sign-in
    When each account reads its own historical or current statement after the replacement
    Then each authorized statement contains only that person's movements and responsibility dates
    And neither account can download the other's private receipt
    And Selin's prior session cannot make a current-occupant change
    And Mert cannot access Selin's household contact details

  @SC-13-10-08 @J-17 @state:F4 @layer:gui @edge @role_resident @pending
  Scenario: A late response cannot repopulate the next tenant's session
    Given a resident has opened their statement on site A and a refresh response is held in the browser
    And a resident of site B has an account with the same unit label and distinct debt and receipts
    When the first resident signs out and the second signs in on the same browser
    And the first resident's held response is released
    Then the app shows the second resident's ledger only
    And back navigation and reload do not expose the first resident's balance or receipt
