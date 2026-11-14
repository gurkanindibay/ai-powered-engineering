@EPIC-12 @STORY-12-03
Feature: People directory
  The people directory shares responsive paging and restoration behavior with the unit directory.

  @SC-12-03-01 @GUI-12-01 @layer:gui @linked @core
  Scenario: People paging and activation filters use the server query
    Given the people directory contains more than one page
    When the manager opens the next page and filters for pending activation
    Then the requested page and filter are sent to the directory API
    And the matching people are shown through the shared directory scaffold

  @SC-12-03-02 @layer:gui @pending @core
  Scenario: People search and directory position survive restoration
    Given the manager has searched and paged through the people directory
    When the app restores the people directory
    Then the search, filters, page size and page are restored
