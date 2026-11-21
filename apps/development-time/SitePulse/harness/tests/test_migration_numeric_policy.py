"""Static check that the SQL migrations keep money exact (EPIC-05 STORY-05-01).

The live schema is verified by scripts/schema_integrity_check.py (gate `schema-integrity`); this
test applies the same NUMERIC policy to the migration sources, so it needs no database.
"""
import re
import unittest
from pathlib import Path

MIGRATIONS = Path(__file__).resolve().parents[2] / "backend" / "migrations"
FLOAT_TYPES = re.compile(r"\b(float4|float8|float|double\s+precision|real)\b", re.IGNORECASE)
MONEY_COLUMN = re.compile(
    r"^\s*([a-z_]*(?:amount|balance|principal|penalty|fee|total|price)[a-z_]*)\s+(numeric|decimal)\b(\([^)]*\))?",
    re.IGNORECASE | re.MULTILINE)


def _sql(path: Path) -> str:
    """Migration text without line comments."""
    return "\n".join(line.split("--", 1)[0] for line in path.read_text(encoding="utf-8").splitlines())


class MigrationNumericPolicy(unittest.TestCase):
    def test_migrations_exist(self):
        self.assertTrue(list(MIGRATIONS.glob("V*.sql")))

    # covers: SC-05-01-01
    def test_no_float_or_double_precision_column_in_any_migration(self):
        for path in sorted(MIGRATIONS.glob("*.sql")):
            with self.subTest(migration=path.name):
                self.assertIsNone(FLOAT_TYPES.search(_sql(path)), f"{path.name} declares a floating-point type")

    # covers: SC-05-01-01
    def test_money_columns_are_numeric_15_2(self):
        found = 0
        for path in sorted(MIGRATIONS.glob("*.sql")):
            for name, _, precision in MONEY_COLUMN.findall(_sql(path)):
                found += 1
                with self.subTest(migration=path.name, column=name):
                    self.assertEqual(re.sub(r"\s", "", precision), "(15,2)")
        self.assertGreater(found, 10, "no money columns found: the pattern no longer matches the migrations")


if __name__ == "__main__":
    unittest.main()
