#!/usr/bin/env python3
"""Read-only integrity and size baseline for the unified people directory."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from typing import Any


QUERIES = {
    "persons_without_site": """
        SELECT count(*) AS count FROM persons
        WHERE site_id IS NULL AND person_type IS DISTINCT FROM 'SAAS_ADMIN'
    """,
    "household_members_without_person": """
        SELECT count(*) AS count FROM occupancy_members WHERE person_id IS NULL
    """,
    "people_with_multiple_active_logins": """
        SELECT count(*) AS count FROM (
            SELECT person_id FROM users
            WHERE is_active AND person_id IS NOT NULL
            GROUP BY person_id HAVING count(*) > 1
        ) duplicates
    """,
    "primary_contacts_without_matching_person": """
        SELECT count(*) AS count
        FROM units u
        WHERE u.primary_responsible_contact IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM persons p
              WHERE p.full_name = u.primary_responsible_contact->>'primary_responsible_name'
                AND (
                    p.id IN (u.owner_person_id, u.tenant_person_id)
                    OR EXISTS (
                        SELECT 1 FROM unit_ownerships o
                        WHERE o.unit_id = u.id AND o.is_active AND o.person_id = p.id
                    )
                    OR EXISTS (
                        SELECT 1 FROM unit_occupancies occ
                        JOIN occupancy_members m ON m.occupancy_id = occ.id
                        WHERE occ.unit_id = u.id AND occ.is_active AND m.person_id = p.id
                    )
                )
          )
    """,
    "likely_duplicate_people": """
        SELECT count(*) AS count FROM (
            SELECT site_id, lower(btrim(full_name)) AS name_key,
                   regexp_replace(coalesce(phone, ''), '\\D', '', 'g') AS phone_key
            FROM persons
            WHERE deleted_at IS NULL AND site_id IS NOT NULL
              AND nullif(regexp_replace(coalesce(phone, ''), '\\D', '', 'g'), '') IS NOT NULL
            GROUP BY site_id, lower(btrim(full_name)),
                     regexp_replace(coalesce(phone, ''), '\\D', '', 'g')
            HAVING count(*) > 1
        ) duplicate_groups
    """,
    "units": "SELECT count(*) AS count FROM units",
}


def _psql_args() -> list[str]:
    if shutil.which("psql") is None and shutil.which("docker") is not None:
        return [
            "docker", "exec", "-i", os.environ.get("DB_CONTAINER", "sitepulse-postgres"),
            "psql", "-U", os.environ.get("DB_USER", "sitepulse_user"),
            "-d", os.environ.get("DB_NAME", "sitepulse"),
        ]
    if os.environ.get("DATABASE_URL"):
        return ["psql", os.environ["DATABASE_URL"]]
    args = [
        "psql",
        "-h", os.environ.get("DB_HOST", "127.0.0.1"),
        "-p", os.environ.get("DB_PORT", "5432"),
        "-U", os.environ.get("DB_USER", "sitepulse_user"),
        "-d", os.environ.get("DB_NAME", "sitepulse"),
    ]
    return args


def _query(sql: str) -> int:
    env = dict(os.environ)
    env.setdefault("PGPASSWORD", env.get("DB_PASS", ""))
    result = subprocess.run(
        _psql_args() + ["-X", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-c", sql],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    if result.returncode:
        message = result.stderr.strip() or "psql query failed"
        raise RuntimeError(message)
    return int(result.stdout.strip())


def collect_report() -> dict[str, Any]:
    return {name: _query(sql) for name, sql in QUERIES.items()}


def _human(report: dict[str, Any]) -> str:
    labels = {
        "persons_without_site": "People without a site (excluding SaaS admins)",
        "household_members_without_person": "Household members without a person link",
        "people_with_multiple_active_logins": "People with multiple active logins",
        "primary_contacts_without_matching_person": "Primary contacts without a matching person",
        "likely_duplicate_people": "Likely duplicate groups (same site, name and phone)",
        "units": "Non-deleted units",
    }
    return "\n".join(f"{labels[key]}: {value}" for key, value in report.items())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    args = parser.parse_args()
    try:
        report = collect_report()
    except (OSError, ValueError, RuntimeError) as error:
        print(f"person integrity report: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2) if args.json else _human(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
