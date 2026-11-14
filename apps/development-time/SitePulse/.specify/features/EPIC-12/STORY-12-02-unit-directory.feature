@EPIC-12 @STORY-12-02
Feature: Compact unit directory
  The unit directory supports a compact responsive list with local paging.

  @SC-12-02-01 @layer:gui @linked @pending @core
  Scenario: Moving to the next page shows the next unit range
    Given a directory containing more units than fit on one page
    When the manager moves to the next page
    Then the directory shows the next page of units

  @SC-12-02-02 @layer:gui @linked @pending @core
  Scenario: Increasing page density reduces the number of pages
    Given a directory with forty matching units
    When the manager selects fifty rows per page
    Then all matching units fit on one page

  @SC-12-02-03 @layer:gui @linked @pending @core
  Scenario: The directory pager adapts to a narrow viewport
    Given the directory is shown in a narrow window
    When the page controls are displayed
    Then the pager wraps without horizontal overflow

  @SC-12-02-04 @layer:gui @linked @pending @core
  Scenario: Large directories build only the visible unit rows
    Given a directory containing one thousand or ten thousand units
    When the first page is shown
    Then only the current page rows are built

  @SC-12-02-05 @layer:gui @linked @core
  Scenario: Unit search folds Turkish names and phone digits
    Given a unit directory containing a Turkish resident name and phone number
    When the manager searches with folded name text or phone digits
    Then the matching unit is included in numeric unit order

  @SC-12-02-06 @layer:gui @linked @core
  Scenario: Unit rows expose distinct actions and details targets
    Given a unit in the directory
    When the manager views its compact row
    Then separate actions and details targets are available

  @SC-12-02-07 @layer:gui @linked @core
  Scenario: Compact unit rows adapt from phone to desktop widths
    Given the unit directory is displayed at widths from 320 to 1440 pixels
    When a compact row is rendered
    Then the unit information and both targets remain visible without overflow

  @SC-12-02-08 @layer:gui @linked @pending @core
  Scenario: Directory page and density survive app restoration
    Given the manager is viewing a later page at a chosen row density
    When the directory is restored
    Then the same page and row density are selected

  @SC-12-02-09 @layer:gui @linked @pending @core
  Scenario: Unit search survives app restoration
    Given the manager has entered a unit search query
    When the directory is restored
    Then the query remains in the search field
