@EPIC-13 @STORY-13-08
Feature: Manager screen and session states
  Use real F0 and F5 responses for empty and populated states. Hold or fail one request at the
  browser boundary for transient states. Network assertions distinguish an intentional error
  from an unexpected failed request on the same route.

  Background:
    Given a SaaS admin has onboarded a site and manager unique to this scenario attempt

  # Verified in the browser by test_first_manager_sign_in_unlocks_the_site_after_password_change.
  @SC-13-08-01 @J-15 @depth:2 @state:F5 @layer:gui @smoke @core @role_manager @linked
  Scenario: The first manager sign-in unlocks a populated site after password change
    Given the site is in state F5 and the manager still has the provisioning password
    When the manager signs in and follows a protected collection deep link
    Then the password change screen is shown and no collection request is sent
    When the manager changes the password and opens the collection dashboard
    Then the F5 total 11117.50 and recognizable A-5 debt are shown
    And no business request is refused with PASSWORD_CHANGE_REQUIRED

  # Verified by focused HTTP failure and recovery journeys for the three surfaces.
  @SC-13-08-02 @J-15 @depth:3 @state:F5 @layer:gui @core @role_manager @linked
  Scenario Outline: Loading, failure and recovery are distinguishable from an empty site
    Given the manager is signed in to a site in state F5
    And the first data request for "<surface>" is held
    When the manager opens "<surface>"
    Then a loading state is displayed without a zero balance or empty result
    When the held request fails once with "<failure>"
    Then the screen reports failure with a recovery action
    When the manager retries or reloads after the service recovers
    Then "<expected>" is shown and the error is cleared

    Examples:
      | surface             | failure       | expected                   |
      | collection tracking | HTTP 503      | outstanding 11117.50       |
      | unit directory      | network error | seven units including A-7  |
      | payment stream      | HTTP 503      | the A-6 payment of 8000.00 |

  @SC-13-08-03 @J-15 @depth:2 @state:F5 @layer:gui @core @role_manager @linked
  Scenario: A search with zero matches is recoverable without changing the site
    Given a manager has opened the populated unit directory in state F5
    When the manager searches for an absent unit label
    Then the directory reports zero matches for the active search
    When the manager clears the search
    Then A-1 through A-7 reappear and the site count remains 7

  @SC-13-08-04 @J-15 @depth:2 @state:F5 @layer:gui @core @role_manager @linked
  Scenario: An expired session cannot reveal a previous manager's data
    Given a manager has opened the collection dashboard of a site in state F5
    And a different manager has a separate site in state F4
    When the first session expires and the backend refuses the next request
    Then the app requests a fresh sign-in and conceals the first site's balances
    When the second manager signs in in the same browser and visits the collection dashboard
    Then only the second site's 8800.00 and its own rows appear
    And browser back and a saved link to the first site reveal no first-site data

  @SC-13-08-05 @J-15 @depth:1 @state:F2 @layer:gui @core @role_manager @linked
  Scenario: Cancelling accrual confirmation makes no financial change
    Given a manager in state F2 has opened the first accrual confirmation with valid inputs
    When the manager cancels and returns to collection tracking
    Then no accrual request was sent and no liabilities exist
    And reopening the accrual form allows the manager to confirm it successfully once

  # Verified by a committed payment whose confirmation response is deliberately lost.
  @SC-13-08-06 @J-15 @depth:1 @state:F5 @layer:gui @core @role_manager @linked
  Scenario: Refreshing a payment after a lost response shows the committed result
    Given the manager enters a 1675.00 payment for unit "A-3" in state F5
    When the server commits the payment but the confirmation response is lost
    And the manager refreshes the payment stream before resubmitting
    Then the matching payment and receipt appear exactly once
    And the screen never reports a second successful payment

  # Verified by two managers submitting against the same vacant unit state.
  @SC-13-08-07 @J-15 @depth:1 @state:F5 @layer:gui @core @role_manager @linked
  Scenario: A stale unit action refreshes after another manager updates occupancy
    Given two managers have opened the same vacant owned unit "A-3" in state F5
    When the first manager moves a tenant into the unit and the second submits a stale move-in action
    Then the second manager sees that the unit state changed
    And a refresh shows the first tenant and actions for a tenant-occupied unit
    And the unit has exactly one active occupancy and no duplicate history or financial movement
