@EPIC-12 @STORY-12-10
Feature: Person actions repeated in cycles keep the card, its status and its history correct
  Every person action is performed several times. After each run the person card, its login
  status, its unit relations and the unit's history are read back, so a repeated action stays
  idempotent or accumulates exactly one record.

  @SC-12-10-01 @layer:backend @linked @core @role_manager
  Scenario: Creating the same person repeatedly never produces a second card
    Given no person named "Ayse Demir" exists on the site
    When the Site Manager creates the card three times with the same email
    Then the first request creates the card and every later one is refused as PERSON_IDENTITY_TAKEN
    And exactly one card exists and its version is unchanged

  @SC-12-10-02 @layer:backend @linked @core @role_manager
  Scenario: Editing a card repeatedly raises the version once per edit and rejects stale versions
    Given the person card "Ayse Demir" at version 0
    When the Site Manager edits the card three times, each time with the version just returned
    Then the version is 3 and the name, phone and email show the last edit
    And an edit sent with an old version is rejected as PERSON_VERSION_CONFLICT and changes nothing

  @SC-12-10-03 @layer:backend @linked @core @role_manager
  Scenario: Opening and removing a login repeatedly keeps the login status correct
    Given the person card "Can Ozturk" with an email
    When the Site Manager opens the login, removes it after a step-up, and repeats this twice
    Then the card shows an open login after each open and no login after each removal
    And only the newest activation link of each round is usable
    And opening a login for a card without an email is refused

  @SC-12-10-04 @layer:backend @linked @edge @role_manager
  Scenario: Opening the login twice in a row reuses the same account
    Given the person card "Can Ozturk" with an email
    When the Site Manager opens the login twice without removing it
    Then exactly one login account exists for the person
    And exactly one unused activation link remains

  @SC-12-10-05 @layer:backend @linked @core @role_manager
  Scenario: A person's card follows the unit actions and keeps the whole relation history
    Given the person card "Selin Demir"
    When Selin moves in as tenant, moves out and moves in again, and then buys the unit through a title transfer
    Then the person card lists a closed tenant relation per completed stay
    And it lists the active owner relation after the transfer
    And the previous owner's card lists a closed owner relation

  @SC-12-10-06 @layer:backend @linked @core @role_manager
  Scenario: Choosing the same existing person for an action repeatedly creates no new card
    Given the person card "Zeynep Kaya" chosen by person id
    When the Site Manager uses the card for a household member, for tenant move-in, for move-out and for tenant move-in again
    Then the number of person cards on the site is unchanged after every action
    And the card shows the matching relations and unit labels after each action

  @SC-12-10-07 @layer:backend @linked @core @role_manager
  Scenario: Contact preferences saved repeatedly keep the last values
    Given the person card "Ayse Demir"
    When the Site Manager saves different contact preferences three times
    Then reading the card after each save returns the latest preferences

  @SC-12-10-08 @layer:backend @linked @core @role_manager
  Scenario: Setting the national id repeatedly keeps it masked and unique
    Given two person cards "Ayse Demir" and "Mehmet Demir"
    When the Site Manager sets a national id on Ayse, sets it again with the same value, then tries the same id on Mehmet
    Then the card only ever shows the masked id
    And the repeated value on the same card is accepted without a second record
    And the same id on another card is refused

  @SC-12-10-09 @layer:backend @linked @core @role_manager
  Scenario: Duplicate cards are merged and the surviving card keeps the history
    Given two cards for the same neighbour who lived in a unit under each card
    When the Site Manager merges the duplicate into the survivor after a step-up
    Then the duplicate no longer exists and its unit relations belong to the survivor
    And repeating the merge is refused and changes nothing
    And the unit's occupancy history still lists both stays

  @SC-12-10-10 @layer:backend @linked @edge @role_manager
  Scenario: Person actions of another site are refused every time
    Given a manager of another site
    When that manager reads, edits, opens a login for and merges a card of this site, twice each
    Then every request is refused and the card, its login status and its history are unchanged

  @SC-12-10-11 @layer:backend @linked @core @role_manager
  Scenario: A person's move-out also moves out their dependents and the cards show it
    Given tenant "Selin Demir" with dependents "Ali Demir" and "Mina Demir" in a unit
    When Selin moves out, moves in again and moves out again
    Then after each move-out the dependents' cards list their household relation as closed
    And after the second move-in the dependents are not on the roster until they are added again
    And the person cards of Selin and both dependents are never deleted
