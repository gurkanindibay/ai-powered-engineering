@EPIC-05 @STORY-05-01
Feature: PostgreSQL relational schema and SQL migrations
  The relational schema is created by versioned migrations with strict NUMERIC(15,2)
  monetary columns. Verified by the migration policy test in
  harness/tests/test_migration_numeric_policy.py and, against a live database, by gate
  schema-integrity (scripts/schema_integrity_check.py).

  @SC-05-01-01 @layer:database @linked
  Scenario: SQL migrations execute with strict NUMERIC types
    When database migrations execute
    Then the core tables are created
    And all monetary balance columns are defined as NUMERIC(15,2)
    And no FLOAT or DOUBLE PRECISION types exist in the schema
