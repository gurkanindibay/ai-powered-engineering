@EPIC-04 @STORY-04-07
Feature: Unit-scoped co-resident invitation link and home permissions
  A home owner invites co-residents with a link bound to their unit only.

  @SC-04-07-01 @GUI-04-06 @layer:gui @linked @core @role_homeowner
  Scenario: Home owner generates unit-scoped invitation link
    Given authenticated home owner Ahmet Yılmaz for unit "A Blok D:14" (unitId: "d-14")
    When generating a resident invite link
    Then produce a tokenized URL "https://sitepulse.app/join/begonya-sitesi/units/d-14?token=SP-HANE-XXXX"
    And state security constraint "Bu link sadece A Blok D:14 yetkisi tanımlar. Başka daire bilgilerine erişemez."

  @SC-04-07-02 @GUI-04-07 @pending @edge @role_resident
  Scenario: Co-resident registers with unit-scoped permissions
    Given a valid unit invite token for "A Blok D:14"
    When Zeynep Yılmaz registers with relationship "SPOUSE"
    Then account is created with role "HOME_RESIDENT" and assigned unitId "d-14"
    And Zeynep can view dues and submit maintenance tickets only for A Blok D:14
    And Zeynep is added to the household member list
