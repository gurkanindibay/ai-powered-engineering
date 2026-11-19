@EPIC-05 @STORY-05-01
Feature: PostgreSQL relational schema and SQL migrations
  The relational schema is created by versioned migrations with strict NUMERIC(15,2)
  monetary columns. Verified today by scripts/schema_integrity_check.py and
  SqlSchemaGate; the traceability linker only reads Rust, Dart and e2e tests, so the
  scenario stays pending until a linkable test declares it.

  @SC-05-01-01 @pending @layer:database @linked
  Scenario: SQL migrations execute with strict NUMERIC types
    When database migrations execute
    Then the core tables are created
    And all monetary balance columns are defined as NUMERIC(15,2)
    And no FLOAT or DOUBLE PRECISION types exist in the schema
